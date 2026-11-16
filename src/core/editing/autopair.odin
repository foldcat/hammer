package editing

import errs "../errs"
import rope "../rope"
import txn "../txn"

Autopair_Pair :: struct {
	open:  u8,
	close: u8,
}

autopair_open_pair :: proc(text: rune) -> (Autopair_Pair, bool) {
	switch text {
	case '(':
		return {'(', ')'}, true
	case '[':
		return {'[', ']'}, true
	case '{':
		return {'{', '}'}, true
	case '"':
		return {'"', '"'}, true
	case '\'':
		return {'\'', '\''}, true
	case '`':
		return {'`', '`'}, true
	}
	return {}, false
}

autopair_close_byte :: proc(text: rune) -> (u8, bool) {
	switch text {
	case ')':
		return ')', true
	case ']':
		return ']', true
	case '}':
		return '}', true
	case '"':
		return '"', true
	case '\'':
		return '\'', true
	case '`':
		return '`', true
	}
	return 0, false
}

MAX_AUTOPAIR_SCAN_LINES :: 1000

autopair_scan_window :: proc(
	tree: ^rope.Tree,
	caret: int,
	allocator := context.allocator,
) -> (rope.Byte_Range, errs.Error) {
	line, err := rope.tree_byte_to_line(tree, caret, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	line_count := rope.tree_line_count(tree)
	first := 0
	last := line_count
	if line_count > MAX_AUTOPAIR_SCAN_LINES {
		first = max(0, int(line) - MAX_AUTOPAIR_SCAN_LINES / 2)
		last = min(line_count, first + MAX_AUTOPAIR_SCAN_LINES)
		if int(line) >= last {
			last = min(line_count, int(line) + 1)
			first = max(0, last - MAX_AUTOPAIR_SCAN_LINES)
		}
	}
	start, start_err := rope.tree_line_start(tree, rope.Line_Index(first), allocator)
	if !errs.ok(start_err) {
		return {}, start_err
	}
	end := rope.tree_byte_count(tree)
	if last < line_count {
		end, err = rope.tree_line_start(tree, rope.Line_Index(last), allocator)
		if !errs.ok(err) {
			return {}, err
		}
	}
	return {start, end}, {}
}

autopair_open_depth :: proc(
	tree: ^rope.Tree,
	range: rope.Byte_Range,
	pair: Autopair_Pair,
	allocator := context.allocator,
) -> (int, errs.Error) {
	it: rope.Tree_Span_Iter
	if err := rope.tree_span_iter_init(&it, tree.root, range, allocator); !errs.ok(err) {
		return 0, err
	}
	depth := 0
	for {
		span, more := rope.tree_span_iter_next(&it, tree)
		if !more {
			break
		}
		for b in span {
			if b == pair.open {
				depth += 1
			} else if b == pair.close && depth > 0 {
				depth -= 1
			}
		}
	}
	return depth, {}
}

autopair_has_matching_close :: proc(
	tree: ^rope.Tree,
	range: rope.Byte_Range,
	pair: Autopair_Pair,
	depth: int,
	allocator := context.allocator,
) -> (bool, errs.Error) {
	it: rope.Tree_Span_Iter
	if err := rope.tree_span_iter_init(&it, tree.root, range, allocator); !errs.ok(err) {
		return false, err
	}
	remaining := depth
	for {
		span, more := rope.tree_span_iter_next(&it, tree)
		if !more {
			break
		}
		for b in span {
			if b == pair.open {
				remaining += 1
			} else if b == pair.close {
				remaining -= 1
				if remaining == 0 {
					return true, {}
				}
			}
		}
	}
	return false, {}
}

autopair_has_existing_close :: proc(
	tree: ^rope.Tree,
	caret: int,
	pair: Autopair_Pair,
	allocator := context.allocator,
) -> (bool, errs.Error) {
	window, err := autopair_scan_window(tree, caret, allocator)
	if !errs.ok(err) {
		return false, err
	}
	depth, depth_err := autopair_open_depth(tree, {window.start, caret}, pair, allocator)
	if !errs.ok(depth_err) {
		return false, depth_err
	}
	return autopair_has_matching_close(tree, {caret, window.end}, pair, depth + 1, allocator)
}

autopair_insert :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	text: rune,
	grouping_key: u64,
	allocator := context.allocator,
) -> (bool, errs.Error) {
	pair, opening := autopair_open_pair(text)
	close, closing := autopair_close_byte(text)
	if !opening && !closing {
		return false, {}
	}

	range := selection_range(selection^)
	if range.start == range.end && closing {
		if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
			return true, err
		}
		if range.start < rope.tree_byte_count(&doc.tree) {
			next: [1]u8
			n, read_err := rope.tree_read(&doc.tree, {range.start, range.start + 1}, next[:], allocator)
			if !errs.ok(read_err) {
				return true, read_err
			}
			if n == 1 && next[0] == close {
				caret := range.start + 1
				selection^ = txn.Selection{anchor = caret, active = caret, affinity = .Left}
				return true, {}
			}
		}
	}
	if !opening {
		return false, {}
	}
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return true, err
	}
	if range.start == range.end {
		inserted := [2]u8{pair.open, pair.close}
		insert_len := 2
		if pair.open != pair.close {
			has_close, close_err := autopair_has_existing_close(&doc.tree, range.start, pair, allocator)
			if !errs.ok(close_err) {
				return true, close_err
			}
			if has_close {
				insert_len = 1
			}
		}
		return true, apply_text_operation(
			doc,
			selection,
			txn.Insert{pos = range.start, data = inserted[:insert_len]},
			range.start + 1,
			grouping_key,
			allocator,
		)
	}

	open_data := [1]u8{pair.open}
	close_data := [1]u8{pair.close}
	ops := []txn.Operation {
		txn.Insert{pos = range.start, data = open_data[:]},
		txn.Insert{pos = range.end, data = close_data[:]},
	}
	after := txn.Selection {
		anchor = selection.anchor + 1,
		active = selection.active + 1,
		affinity = selection.affinity,
	}
	return true, apply_text_operations(doc, selection, ops, after, grouping_key, allocator)
}

autopair_delete_backward :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	allocator := context.allocator,
) -> (bool, errs.Error) {
	if selection.anchor != selection.active {
		return false, {}
	}
	caret := selection.active
	if caret <= 0 || caret >= rope.tree_byte_count(&doc.tree) {
		return false, {}
	}
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return true, err
	}
	bytes: [2]u8
	n, read_err := rope.tree_read(&doc.tree, {caret - 1, caret + 1}, bytes[:], allocator)
	if !errs.ok(read_err) {
		return true, read_err
	}
	if n != 2 {
		return false, {}
	}
	pair, ok := autopair_open_pair(rune(bytes[0]))
	if !ok || pair.close != bytes[1] {
		return false, {}
	}
	return true, apply_text_operation(
		doc,
		selection,
		txn.Delete{range = {caret - 1, caret + 1}},
		caret - 1,
		0,
		allocator,
	)
}
