package process

import "base:runtime"

import console "../console"
import errs "../errs"
import rope "../rope"
import txn "../txn"

DEFAULT_OUTPUT_BATCH_BYTES :: 64 * 1024
DEFAULT_SCROLLBACK_BYTES :: 1024 * 1024
MAX_OUTPUT_BATCH_BYTES :: 1024 * 1024
MAX_SCROLLBACK_BYTES :: 16 * 1024 * 1024

Output_Options :: struct {
	batch_bytes:      int,
	scrollback_bytes: int,
}

Output_Update :: struct {
	transaction: txn.Transaction,
	end:         int,
	trimmed:     int,
	consumed:    int,
}

// Output_Buffer borrows a document and applies at most one transaction per
// consume/append call. Its pending storage is fixed at initialization and its
// decoded output buffer grows as needed, bounded by the console line buffer's
// cell budget plus one batch (a partial line carried across a batch boundary is
// emitted whole when it completes). Output history is collapsed after every
// successful update so both rope scrollback and retained undo storage stay
// bounded. The update borrows operation storage owned by Output_Buffer until
// the next consume/append or destroy.
//
// Raw output bytes are decoded through a console.Stream before reaching the
// document (SPECS §12.5 model A): ANSI escape sequences are consumed, and CR/
// backspace/erase progress collapses. All writers (output_consume, output_append,
// selection_pipe_consume stderr, regex_search_consume stderr, selection_pipe_replay)
// funnel through pending
// and output_flush, so every path decodes uniformly.
Output_Buffer :: struct {
	allocator:     runtime.Allocator,
	doc:           ^txn.Doc,
	options:       Output_Options,
	pending:       []byte,
	pending_len:   int,
	decoded:       [dynamic]byte,
	stream:        console.Stream,
	ops:           [2]txn.Operation,
	update:        Output_Update,
	has_update:    bool,
	dropped_bytes: u64,
}

output_init :: proc(buffer: ^Output_Buffer, doc: ^txn.Doc, options: Output_Options = {}, allocator := context.allocator) -> errs.Error {
	if buffer == nil || doc == nil {
		return errs.new(.Invalid_Input, "process: output buffer requires a document", allocator = allocator)
	}
	resolved := options
	if resolved.batch_bytes == 0 {
		resolved.batch_bytes = DEFAULT_OUTPUT_BATCH_BYTES
	}
	if resolved.scrollback_bytes == 0 {
		resolved.scrollback_bytes = DEFAULT_SCROLLBACK_BYTES
	}
	if resolved.batch_bytes < 0 || resolved.scrollback_bytes < 0 || resolved.batch_bytes > resolved.scrollback_bytes {
		return errs.new(.Invalid_Input, "process: output batch must be positive and no larger than scrollback", allocator = allocator)
	}
	if resolved.batch_bytes > MAX_OUTPUT_BATCH_BYTES || resolved.scrollback_bytes > MAX_SCROLLBACK_BYTES {
		return errs.new(.Resource_Limit, "process: output buffer exceeds its configured budget", allocator = allocator)
	}
	pending, alloc_err := make([]byte, resolved.batch_bytes, allocator)
	if alloc_err != nil {
		return errs.new(.Resource_Limit, "process: cannot allocate output batch storage", allocator = allocator)
	}
	stream: console.Stream
	if err := console.stream_init(&stream, allocator); !errs.ok(err) {
		delete(pending, allocator)
		return err
	}
	buffer^ = {
		allocator = allocator,
		doc = doc,
		options = resolved,
		pending = pending,
		decoded = make([dynamic]byte, allocator),
		stream = stream,
	}
	return {}
}

output_flush :: proc(buffer: ^Output_Buffer) -> errs.Error {
	if buffer.pending_len == 0 {
		return {}
	}
	resize(&buffer.decoded, 0)
	if err := console.stream_feed(&buffer.stream, buffer.pending[:buffer.pending_len], &buffer.decoded); !errs.ok(err) {
		buffer.pending_len = 0
		buffer.has_update = false
		return err
	}
	buffer.pending_len = 0
	return output_append_decoded(buffer)
}

// output_append_decoded appends buffer.decoded to the document with scrollback
// trimming. It borrows buffer.decoded until the next flush. A zero-length
// decode (for example, input consisting only of escape sequences) leaves
// has_update untouched so an earlier update in the same consume is not lost.
output_append_decoded :: proc(buffer: ^Output_Buffer) -> errs.Error {
	decoded_len := len(buffer.decoded)
	if decoded_len == 0 {
		return {}
	}
	start := rope.tree_byte_count(&buffer.doc.tree)
	trimmed := max(0, start + decoded_len - buffer.options.scrollback_bytes)
	operation_count := 1
	if trimmed > 0 {
		buffer.ops[0] = txn.Delete{range = {0, trimmed}}
		buffer.ops[1] = txn.Insert{pos = start, data = buffer.decoded[:decoded_len]}
		operation_count = 2
	} else {
		buffer.ops[0] = txn.Insert{pos = start, data = buffer.decoded[:decoded_len]}
	}
	end := start - trimmed + decoded_len
	buffer.update = {
		transaction = {
			source = .Command_Output,
			base_revision = txn.doc_revision(buffer.doc),
			ops = buffer.ops[:operation_count],
			after_selection = {anchor = end, active = end, affinity = .Left},
		},
		end = end,
		trimmed = trimmed,
	}
	if err := txn.doc_apply(buffer.doc, &buffer.update.transaction, buffer.allocator); !errs.ok(err) {
		buffer.has_update = false
		return err
	}
	buffer.dropped_bytes += u64(trimmed)
	buffer.has_update = true
	txn.doc_collapse_history(buffer.doc)
	return {}
}

// output_clear starts a new output generation in the same document. The clear
// is one transaction; decoder state and pending partial lines are replaced only
// after that transaction succeeds.
output_clear :: proc(buffer: ^Output_Buffer) -> errs.Error {
	if buffer == nil || buffer.doc == nil {
		return errs.new(.Invalid_Input, "process: invalid output clear input")
	}
	stream: console.Stream
	if err := console.stream_init(&stream, buffer.allocator); !errs.ok(err) {
		return err
	}
	buffer.has_update = false
	end := rope.tree_byte_count(&buffer.doc.tree)
	if end > 0 {
		buffer.ops[0] = txn.Delete{range = {0, end}}
		buffer.update = {
			transaction = {
				source = .Command_Output,
				base_revision = txn.doc_revision(buffer.doc),
				ops = buffer.ops[:1],
				after_selection = {},
			},
			end = 0,
			trimmed = 0,
		}
		if err := txn.doc_apply(buffer.doc, &buffer.update.transaction, buffer.allocator); !errs.ok(err) {
			console.stream_destroy(&stream)
			return err
		}
		buffer.has_update = true
		txn.doc_collapse_history(buffer.doc)
	}
	console.stream_destroy(&buffer.stream)
	buffer.stream = stream
	buffer.pending_len = 0
	resize(&buffer.decoded, 0)
	buffer.dropped_bytes = 0
	return {}
}

// output_finish flushes the console stream's trailing state — a truncated
// UTF-8 replacement and any partial trailing line — into the document. Call it
// once the pump has drained and no further output is expected. It is
// idempotent.
output_finish :: proc(buffer: ^Output_Buffer) -> errs.Error {
	if buffer == nil || buffer.doc == nil {
		return errs.new(.Invalid_Input, "process: invalid output finish input")
	}
	buffer.has_update = false
	if buffer.pending_len > 0 {
		if err := output_flush(buffer); !errs.ok(err) {
			return err
		}
	}
	resize(&buffer.decoded, 0)
	if err := console.stream_flush(&buffer.stream, &buffer.decoded); !errs.ok(err) {
		return err
	}
	return output_append_decoded(buffer)
}

output_consume :: proc(buffer: ^Output_Buffer, pump: ^Pump, max_bytes: int) -> (int, errs.Error) {
	if buffer == nil || buffer.doc == nil || pump == nil || max_bytes < 0 {
		return 0, errs.new(.Invalid_Input, "process: invalid output consumption input")
	}
	buffer.has_update = false
	if max_bytes == 0 {
		return 0, {}
	}
	if err := output_flush(buffer); !errs.ok(err) {
		return 0, err
	}
	budget := min(max_bytes, buffer.options.batch_bytes)
	consumed := 0
	for consumed < budget {
		record, ok := pump_next(pump)
		if !ok {
			break
		}
		if record.kind == .End {
			pump_release(pump)
			continue
		}
		if record.kind == .Error {
			err := errs.new(record.err.kind, record.err.message, allocator = buffer.allocator)
			pump_release(pump)
			if flush_err := output_flush(buffer); !errs.ok(flush_err) {
				errs.destroy(&err)
				return consumed, flush_err
			}
			buffer.update.consumed = consumed
			return consumed, err
		}
		count := min(len(record.data), budget - consumed)
		copy(buffer.pending[buffer.pending_len:], record.data[:count])
		buffer.pending_len += count
		record.data = record.data[count:]
		pump.buffered_bytes -= count
		consumed += count
		if len(record.data) == 0 {
			pump_release(pump)
		}
	}
	if err := output_flush(buffer); !errs.ok(err) {
		return consumed, err
	}
	buffer.update.consumed = consumed
	return consumed, {}
}

output_append :: proc(buffer: ^Output_Buffer, data: []byte) -> errs.Error {
	if buffer == nil || buffer.doc == nil || len(data) > buffer.options.batch_bytes {
		return errs.new(.Resource_Limit, "process: direct output append exceeds the batch budget")
	}
	buffer.has_update = false
	if err := output_flush(buffer); !errs.ok(err) {
		return err
	}
	copy(buffer.pending, data)
	buffer.pending_len = len(data)
	if err := output_flush(buffer); !errs.ok(err) {
		return err
	}
	buffer.update.consumed = len(data)
	return {}
}

output_destroy :: proc(buffer: ^Output_Buffer) {
	if buffer == nil {
		return
	}
	console.stream_destroy(&buffer.stream)
	delete(buffer.decoded)
	delete(buffer.pending, buffer.allocator)
	buffer^ = {}
}
