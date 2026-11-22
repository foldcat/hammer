package process

import "base:runtime"
import "core:strconv"
import "core:strings"

import errs "../errs"
import rope "../rope"
import txn "../txn"

MAX_REGEX_SEARCH_OUTPUT_BYTES :: 128

Regex_Search_State :: enum u8 {
	Collecting,
	Ready,
	Applied,
	Conflict,
	Failed,
}

// Regex_Search owns an immutable whole-document input snapshot and a bounded
// stdout record. Its target identity and source revision prevent a late match
// from being applied to a different document revision.
Regex_Search :: struct {
	target:     Selection_Target,
	state:      Regex_Search_State,
	input:      []byte,
	output:     [MAX_REGEX_SEARCH_OUTPUT_BYTES]byte,
	output_len: int,
	allocator:  runtime.Allocator,
}

regex_search_init :: proc(
	search: ^Regex_Search,
	doc: ^txn.Doc,
	selection: txn.Selection,
	target_id: u64,
	target_generation: u64,
	request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if search == nil || doc == nil || target_id == 0 || target_generation == 0 || request_id == 0 {
		return errs.new(.Invalid_Input, "regex: search requires a document and nonzero target identity", allocator = allocator)
	}
	total := rope.tree_byte_count(&doc.tree)
	if total > MAX_SELECTION_INPUT_BYTES {
		return errs.newf(.Resource_Limit, "regex: document exceeds the %d-byte search input budget", MAX_SELECTION_INPUT_BYTES, allocator = allocator)
	}
	if !txn.selection_in_bounds(selection, total) {
		return errs.new(.Invalid_Input, "regex: search selection is outside the document", allocator = allocator)
	}
	input, read_err := rope.tree_read_all(&doc.tree, {0, total}, allocator)
	if !errs.ok(read_err) {
		return read_err
	}
	search^ = {
		target = {
			id = target_id,
			generation = target_generation,
			source_revision = txn.doc_revision(doc),
			request_id = request_id,
			range = {min(selection.anchor, selection.active), max(selection.anchor, selection.active)},
			selection = selection,
		},
		state = .Collecting,
		input = input,
		allocator = allocator,
	}
	return {}
}

regex_search_destroy :: proc(search: ^Regex_Search) {
	if search == nil {
		return
	}
	delete(search.input, search.allocator)
	search^ = {}
}

// regex_search_consume captures only the small stdout offset record. Stderr is
// decoded into the ordinary job diagnostics window.
regex_search_consume :: proc(search: ^Regex_Search, pump: ^Pump, diagnostics: ^Output_Buffer, max_bytes: int) -> (int, errs.Error) {
	if search == nil || pump == nil || diagnostics == nil || max_bytes < 0 || search.state != .Collecting {
		return 0, errs.new(.Invalid_Input, "regex: invalid search output consumption input")
	}
	diagnostics.has_update = false
	if max_bytes == 0 {
		return 0, {}
	}
	if err := output_flush(diagnostics); !errs.ok(err) {
		return 0, err
	}
	budget := min(max_bytes, DEFAULT_OUTPUT_BATCH_BYTES, diagnostics.options.batch_bytes)
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
			err := errs.new(record.err.kind, record.err.message, allocator = search.allocator)
			pump_release(pump)
			search.state = .Failed
			if flush_err := output_flush(diagnostics); !errs.ok(flush_err) {
				errs.destroy(&err)
				return consumed, flush_err
			}
			return consumed, err
		}
		count := min(len(record.data), budget - consumed)
		if record.stream == .Stdout {
			if len(record.data) > len(search.output) - search.output_len {
				search.state = .Failed
				return consumed, errs.newf(
					.Resource_Limit,
					"regex: search result exceeds the %d-byte budget",
					len(search.output),
					allocator = search.allocator,
				)
			}
			copy(search.output[search.output_len:], record.data[:count])
			search.output_len += count
		} else {
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
	if err := output_flush(diagnostics); !errs.ok(err) {
		return consumed, err
	}
	if diagnostics.has_update {
		diagnostics.update.consumed = diagnostic_bytes
	}
	return consumed, {}
}

regex_search_ready :: proc(search: ^Regex_Search) {
	if search != nil && search.state == .Collecting {
		search.state = .Ready
	}
}

regex_search_abort :: proc(search: ^Regex_Search) {
	if search != nil && search.state != .Applied {
		search.state = .Failed
	}
}

regex_search_reject :: proc(search: ^Regex_Search) {
	if search != nil && search.state != .Applied {
		search.state = .Conflict
	}
}

regex_search_apply :: proc(search: ^Regex_Search, doc: ^txn.Doc, target_id: u64, target_generation: u64, request_id: u64) -> (rope.Byte_Range, errs.Error) {
	if search == nil || doc == nil || search.state != .Ready {
		return {}, errs.new(.Invalid_Input, "regex: search is not ready to apply")
	}
	if search.target.id != target_id || search.target.generation != target_generation || search.target.request_id != request_id {
		search.state = .Conflict
		return {}, errs.new(.Conflict, "regex: search target or request is stale", allocator = search.allocator)
	}
	if search.target.source_revision != txn.doc_revision(doc) {
		search.state = .Conflict
		return {}, errs.new(.Conflict, "regex: source document changed while the external search was running", allocator = search.allocator)
	}
	match, parse_err := regex_search_parse_match(search.output[:search.output_len], rope.tree_byte_count(&doc.tree), search.allocator)
	if !errs.ok(parse_err) {
		search.state = .Failed
		return {}, parse_err
	}
	positions := [2]int{match.start, match.end}
	for position in positions {
		scalar, scalar_err := rope.tree_byte_to_scalar(&doc.tree, position, search.allocator)
		if !errs.ok(scalar_err) {
			search.state = .Failed
			return {}, scalar_err
		}
		byte_position, byte_err := rope.tree_scalar_to_byte(&doc.tree, scalar, search.allocator)
		if !errs.ok(byte_err) {
			search.state = .Failed
			return {}, byte_err
		}
		if byte_position != position {
			search.state = .Failed
			return {}, errs.new(.Invalid_Input, "regex: external match is not on a UTF-8 scalar boundary", allocator = search.allocator)
		}
	}
	search.state = .Applied
	return match, {}
}

regex_search_parse_match :: proc(output: []byte, document_bytes: int, allocator := context.allocator) -> (rope.Byte_Range, errs.Error) {
	remaining := strings.trim_space(string(output))
	first, ok := strings.fields_iterator(&remaining)
	if !ok {
		return {}, errs.new(.Invalid_Input, "regex: external search returned an empty result", allocator = allocator)
	}
	second, second_ok := strings.fields_iterator(&remaining)
	_, extra := strings.fields_iterator(&remaining)
	if !second_ok || extra {
		return {}, errs.new(.Invalid_Input, "regex: external search result must contain exactly two byte offsets", allocator = allocator)
	}
	start, start_ok := strconv.parse_u64(first, 10)
	end, end_ok := strconv.parse_u64(second, 10)
	max_int := u64(~uint(0) >> 1)
	if !start_ok || !end_ok || start > max_int || end > max_int {
		return {}, errs.new(.Invalid_Input, "regex: external search returned invalid byte offsets", allocator = allocator)
	}
	match := rope.Byte_Range{start = int(start), end = int(end)}
	if match.start < 0 || match.end < match.start || match.end > document_bytes {
		return {}, errs.new(.Invalid_Input, "regex: external search match is outside the source document", allocator = allocator)
	}
	return match, {}
}
