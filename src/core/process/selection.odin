package process

import "base:runtime"

import errs "../errs"
import rope "../rope"
import txn "../txn"

DEFAULT_SELECTION_OUTPUT_BYTES :: 1024 * 1024
MAX_SELECTION_INPUT_BYTES :: 16 * 1024 * 1024
MAX_SELECTION_OUTPUT_BYTES :: 16 * 1024 * 1024

Selection_Pipe_State :: enum u8 {
	Collecting,
	Ready,
	Applied,
	Conflict,
	Failed,
}

Selection_Target :: struct {
	id:              u64,
	generation:      u64,
	window_id:       u64,
	source_revision: u64,
	request_id:      u64,
	range:           rope.Byte_Range,
	selection:       txn.Selection,
}

Selection_Pipe_Options :: struct {
	output_bytes: int,
	// empty_input closes stdin without feeding the selection. Used by the
	// `<command` routing, which replaces the selection with command output
	// while providing no input. The target range is still captured for the
	// replacement and its stale-target validation.
	empty_input:  bool,
	// whole_buffer_input_when_empty feeds the entire document when the target
	// selection is a caret. A non-empty selection remains the input. The target
	// range and output replacement semantics are unchanged.
	whole_buffer_input_when_empty: bool,
}

// Selection_Pipe owns independent selection input and fixed-capacity stdout
// storage. apply borrows that storage until the next pipe operation or destroy.
Selection_Pipe :: struct {
	allocator:     runtime.Allocator,
	target:        Selection_Target,
	state:         Selection_Pipe_State,
	options:       Selection_Pipe_Options,
	input:         []byte,
	output:        []byte,
	output_len:    int,
	replay_offset: int,
	operations:    [1]txn.Operation,
	transaction:   txn.Transaction,
	has_update:    bool,
}

selection_pipe_init :: proc(
	pipe: ^Selection_Pipe,
	doc: ^txn.Doc,
	selection: txn.Selection,
	target_id: u64,
	target_generation: u64,
	request_id: u64,
	options: Selection_Pipe_Options = {},
	allocator := context.allocator,
) -> errs.Error {
	if pipe == nil || doc == nil || target_id == 0 || target_generation == 0 || request_id == 0 {
		return errs.new(.Invalid_Input, "process: selection pipe requires a document and nonzero target identity", allocator = allocator)
	}
	if !txn.selection_in_bounds(selection, rope.tree_byte_count(&doc.tree)) {
		return errs.new(.Invalid_Input, "process: selection pipe selection is outside the document", allocator = allocator)
	}
	resolved := options
	if resolved.output_bytes == 0 {
		resolved.output_bytes = DEFAULT_SELECTION_OUTPUT_BYTES
	}
	if resolved.output_bytes < 0 {
		return errs.new(.Invalid_Input, "process: selection pipe output capacity must be positive", allocator = allocator)
	}
	if resolved.output_bytes > MAX_SELECTION_OUTPUT_BYTES {
		return errs.newf(.Resource_Limit, "process: selection pipe output exceeds the %d-byte budget", MAX_SELECTION_OUTPUT_BYTES, allocator = allocator)
	}
	range := rope.Byte_Range{min(selection.anchor, selection.active), max(selection.anchor, selection.active)}
	input_range := range
	if resolved.whole_buffer_input_when_empty && range.start == range.end {
		input_range = {0, rope.tree_byte_count(&doc.tree)}
	}
	input: []byte
	if !resolved.empty_input {
		if input_range.end - input_range.start > MAX_SELECTION_INPUT_BYTES {
			return errs.newf(.Resource_Limit, "process: selection pipe input exceeds the %d-byte budget", MAX_SELECTION_INPUT_BYTES, allocator = allocator)
		}
		read, read_err := rope.tree_read_all(&doc.tree, input_range, allocator)
		if !errs.ok(read_err) {
			return read_err
		}
		input = read
	}
	output, alloc_err := make([]byte, resolved.output_bytes, allocator)
	if alloc_err != nil {
		delete(input, allocator)
		return errs.new(.Resource_Limit, "process: cannot allocate selection output storage", allocator = allocator)
	}
	pipe^ = {
		allocator = allocator,
		target = {
			id = target_id,
			generation = target_generation,
			source_revision = txn.doc_revision(doc),
			request_id = request_id,
			range = range,
			selection = selection,
		},
		state = .Collecting,
		options = resolved,
		input = input,
		output = output,
	}
	return {}
}

selection_pipe_destroy :: proc(pipe: ^Selection_Pipe) {
	if pipe == nil {
		return
	}
	delete(pipe.input, pipe.allocator)
	delete(pipe.output, pipe.allocator)
	pipe^ = {}
}

// selection_pipe_consume routes stdout to the fixed result buffer and stderr
// to diagnostics. A nil diagnostics buffer explicitly discards stderr.
selection_pipe_consume :: proc(pipe: ^Selection_Pipe, pump: ^Pump, diagnostics: ^Output_Buffer, max_bytes: int) -> (int, errs.Error) {
	if pipe == nil || pump == nil || max_bytes < 0 || pipe.state != .Collecting {
		return 0, errs.new(.Invalid_Input, "process: invalid selection pipe consumption input")
	}
	if diagnostics != nil {
		diagnostics.has_update = false
	}
	if max_bytes == 0 {
		return 0, {}
	}
	if diagnostics != nil {
		if err := output_flush(diagnostics); !errs.ok(err) {
			return 0, err
		}
	}
	budget := min(max_bytes, DEFAULT_OUTPUT_BATCH_BYTES)
	if diagnostics != nil {
		budget = min(budget, diagnostics.options.batch_bytes)
	}
	consumed := 0
	diagnostic_bytes := 0
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
			err := errs.new(record.err.kind, record.err.message, allocator = pipe.allocator)
			pump_release(pump)
			pipe.state = .Failed
			if diagnostics != nil {
				if flush_err := output_flush(diagnostics); !errs.ok(flush_err) {
					errs.destroy(&err)
					return consumed, flush_err
				}
			}
			return consumed, err
		}
		count := min(len(record.data), budget - consumed)
		if record.stream == .Stdout {
			if len(record.data) > len(pipe.output) - pipe.output_len {
				pipe.state = .Failed
				return consumed, errs.newf(
					.Resource_Limit,
					"process: selection output exceeds the %d-byte budget",
					len(pipe.output),
					allocator = pipe.allocator,
				)
			}
			copy(pipe.output[pipe.output_len:], record.data[:count])
			pipe.output_len += count
		} else if diagnostics != nil {
			copy(diagnostics.pending[diagnostics.pending_len:], record.data[:count])
			diagnostics.pending_len += count
			diagnostic_bytes += count
		}
		record.data = record.data[count:]
		pump.buffered_bytes -= count
		consumed += count
		if len(record.data) == 0 {
			pump_release(pump)
		}
	}
	if diagnostics != nil {
		if err := output_flush(diagnostics); !errs.ok(err) {
			return consumed, err
		}
		if diagnostics.has_update {
			diagnostics.update.consumed = diagnostic_bytes
		}
	}
	return consumed, {}
}

selection_pipe_ready :: proc(pipe: ^Selection_Pipe) {
	if pipe != nil && pipe.state == .Collecting {
		pipe.state = .Ready
	}
}

selection_pipe_abort :: proc(pipe: ^Selection_Pipe) {
	if pipe != nil && pipe.state != .Applied {
		pipe.state = .Failed
	}
}

selection_pipe_reject :: proc(pipe: ^Selection_Pipe) {
	if pipe != nil && pipe.state != .Applied {
		pipe.state = .Conflict
	}
}

selection_insert_conflicts :: proc(target: rope.Byte_Range, pos, length: int) -> bool {
	if length == 0 {
		return false
	}
	if target.start == target.end {
		return pos == target.start
	}
	return pos > target.start && pos < target.end
}

selection_range_conflicts :: proc(target, edit: rope.Byte_Range) -> bool {
	if edit.start == edit.end {
		return false
	}
	if target.start == target.end {
		return edit.start < target.start && target.start < edit.end
	}
	return edit.start < target.end && target.start < edit.end
}

selection_operation_conflicts :: proc(target: rope.Byte_Range, op: txn.Operation) -> bool {
	switch operation in op {
	case txn.Insert:
		return selection_insert_conflicts(target, operation.pos, len(operation.data))
	case txn.Delete:
		return selection_range_conflicts(target, operation.range)
	case txn.Replace:
		if operation.range.start == operation.range.end {
			return selection_insert_conflicts(target, operation.range.start, len(operation.data))
		}
		if target.start == target.end && operation.range.start == target.start && len(operation.data) > 0 {
			return true
		}
		return selection_range_conflicts(target, operation.range)
	}
	return true
}

selection_pipe_current_range :: proc(pipe: ^Selection_Pipe, doc: ^txn.Doc) -> (rope.Byte_Range, errs.Error) {
	source_revision := pipe.target.source_revision
	found := source_revision == 0
	for node := doc.current; node != 0; {
		entry := &doc.log[node - 1]
		if entry.after == source_revision {
			found = true
			break
		}
		for op in entry.ops {
			if selection_operation_conflicts(pipe.target.range, op) {
				return {}, errs.new(.Conflict, "process: selection target range has newer edits", allocator = pipe.allocator)
			}
		}
		node = entry.parent
	}
	if !found {
		return {}, errs.newf(
			.Conflict,
			"process: selection source revision %d is not on the current history path",
			source_revision,
			allocator = pipe.allocator,
		)
	}
	start := txn.Anchor{pos = pipe.target.range.start, affinity = .Left, revision = source_revision}
	end := txn.Anchor{pos = pipe.target.range.end, affinity = .Right, revision = source_revision}
	if err := txn.anchor_transform(doc, &start, pipe.allocator); !errs.ok(err) {
		return {}, err
	}
	if err := txn.anchor_transform(doc, &end, pipe.allocator); !errs.ok(err) {
		return {}, err
	}
	if start.pos > end.pos {
		return {}, errs.new(.Conflict, "process: transformed selection range is ambiguous", allocator = pipe.allocator)
	}
	return rope.Byte_Range{start.pos, end.pos}, {}
}

selection_pipe_replace :: proc(pipe: ^Selection_Pipe, doc: ^txn.Doc, range: rope.Byte_Range, selection: txn.Selection) -> errs.Error {
	pipe.has_update = false
	start := range.start
	end := start + pipe.output_len
	pipe.operations[0] = txn.Replace{range = range, data = pipe.output[:pipe.output_len]}
	after := txn.Selection{anchor = start, active = end, affinity = .Right}
	if selection.anchor > selection.active {
		after.anchor, after.active = after.active, after.anchor
	}
	pipe.transaction = {
		source = .Command_Output,
		base_revision = txn.doc_revision(doc),
		ops = pipe.operations[:],
		after_selection = after,
	}
	if err := txn.doc_apply(doc, &pipe.transaction, pipe.allocator); !errs.ok(err) {
		pipe.state = .Conflict if err.kind == .Conflict else .Failed
		return err
	}
	pipe.target.range = range
	pipe.target.source_revision = txn.doc_revision(doc)
	pipe.target.selection = selection
	pipe.state = .Applied
	pipe.has_update = true
	return {}
}

selection_pipe_apply :: proc(pipe: ^Selection_Pipe, doc: ^txn.Doc, target_id: u64, target_generation: u64, request_id: u64) -> errs.Error {
	if pipe == nil || doc == nil || pipe.state != .Ready {
		return errs.new(.Invalid_Input, "process: selection pipe is not ready to apply")
	}
	pipe.has_update = false
	if pipe.target.id != target_id || pipe.target.generation != target_generation || pipe.target.request_id != request_id {
		pipe.state = .Conflict
		return errs.new(.Conflict, "process: selection pipe target or request is stale", allocator = pipe.allocator)
	}
	range := pipe.target.range
	if pipe.target.source_revision != txn.doc_revision(doc) {
		current_range, err := selection_pipe_current_range(pipe, doc)
		if !errs.ok(err) {
			pipe.state = .Conflict if err.kind == .Conflict else .Failed
			return err
		}
		range = current_range
	}
	return selection_pipe_replace(pipe, doc, range, pipe.target.selection)
}

// Explicit application replaces the caller's current selection, not the stale
// range. The user therefore chooses exactly which newer text may be replaced.
selection_pipe_apply_explicit :: proc(
	pipe: ^Selection_Pipe,
	doc: ^txn.Doc,
	target_id: u64,
	target_generation: u64,
	request_id: u64,
	selection: txn.Selection,
) -> errs.Error {
	if pipe == nil || doc == nil || pipe.state != .Conflict {
		return errs.new(.Invalid_Input, "process: selection pipe has no conflict to apply")
	}
	pipe.has_update = false
	if pipe.target.id != target_id || pipe.target.generation != target_generation || pipe.target.request_id != request_id {
		return errs.new(.Conflict, "process: selection pipe target or request is stale", allocator = pipe.allocator)
	}
	if !txn.selection_in_bounds(selection, rope.tree_byte_count(&doc.tree)) {
		return errs.new(.Invalid_Input, "process: explicit selection is outside the document", allocator = pipe.allocator)
	}
	range := rope.Byte_Range{min(selection.anchor, selection.active), max(selection.anchor, selection.active)}
	return selection_pipe_replace(pipe, doc, range, selection)
}

selection_pipe_replay_done :: proc(pipe: ^Selection_Pipe) -> bool {
	return pipe != nil && pipe.replay_offset == pipe.output_len
}

selection_pipe_replay :: proc(pipe: ^Selection_Pipe, diagnostics: ^Output_Buffer, max_bytes: int) -> (int, errs.Error) {
	if pipe == nil || diagnostics == nil || max_bytes < 0 || (pipe.state != .Conflict && pipe.state != .Failed) {
		return 0, errs.new(.Invalid_Input, "process: invalid selection output replay input")
	}
	count := min(max_bytes, pipe.output_len - pipe.replay_offset, diagnostics.options.batch_bytes)
	if count == 0 {
		return 0, {}
	}
	if err := output_append(diagnostics, pipe.output[pipe.replay_offset:pipe.replay_offset + count]); !errs.ok(err) {
		return 0, err
	}
	pipe.replay_offset += count
	return count, {}
}
