package editing

import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"
import txn "../txn"

// Insert_Text replaces the current selection with one Unicode scalar. A shared
// nonzero grouping_key joins consecutive typing transactions into one undo unit.
// Newline insertion also inherits the first selected line's leading whitespace.
Insert_Text :: struct {
	text:         rune,
	grouping_key: u64,
}

// Commit_Text inserts one complete IME commit atomically. text is borrowed only
// during perform; the transaction log owns its copy.
Commit_Text :: struct {
	text:         string,
	grouping_key: u64,
}

Delete_Backward :: struct {}
Delete_Word_Backward :: struct {}
Delete_Forward :: struct {}

insert_text :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	text: rune,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	if !valid_committed_rune(text) {
		return errs.new(.Invalid_Input, "editing: invalid committed text scalar", allocator = allocator)
	}
	if text == '\n' {
		return insert_newline(doc, selection, grouping_key, {}, false, allocator)
	}
	encoded, width := utf8.encode_rune(text)
	return insert_committed_bytes(doc, selection, encoded[:width], grouping_key, allocator)
}

insert_newline :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	grouping_key: u64,
	pair_indent: Indent_Settings,
	indent_pair: bool,
	allocator := context.allocator,
) -> errs.Error {
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	range := selection_range(selection^)
	line, err := read_line_at(&doc.tree, range.start, allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(line.data, allocator)

	indent_len := 0
	for indent_len < len(line.data) && (line.data[indent_len] == ' ' || line.data[indent_len] == '\t') {
		indent_len += 1
	}
	extra_indent := 0
	if indent_pair && range.start == range.end && range.start > 0 && range.start < rope.tree_byte_count(&doc.tree) {
		bytes: [2]u8
		n, read_err := rope.tree_read(&doc.tree, {range.start - 1, range.start + 1}, bytes[:], allocator)
		if !errs.ok(read_err) {
			return read_err
		}
		pair, paired := autopair_open_pair(rune(bytes[0]))
		if n == 2 && paired && pair.open != pair.close && pair.close == bytes[1] {
			width := pair_indent.width
			if width == 0 {
				width = DEFAULT_INDENT_WIDTH
			}
			if width < 0 || width > MAX_INDENT_WIDTH ||
				(pair_indent.style != .Tabs && pair_indent.style != .Spaces) {
				return errs.new(.Invalid_Input, "editing: invalid indentation settings", allocator = allocator)
			}
			extra_indent = width
			if pair_indent.style == .Tabs {
				extra_indent = 1
			}
		}
	}
	closing_line_len := 0
	if extra_indent > 0 {
		closing_line_len = indent_len + 1
	}
	inserted := make([]byte, indent_len + 1 + extra_indent + closing_line_len, allocator)
	defer delete(inserted, allocator)
	inserted[0] = '\n'
	copy(inserted[1:], line.data[:indent_len])
	caret := range.start + len(inserted)
	if extra_indent > 0 {
		unit := inserted[indent_len + 1:indent_len + 1 + extra_indent]
		if pair_indent.style == .Tabs {
			unit[0] = '\t'
		} else {
			for &b in unit {
				b = ' '
			}
		}
		caret = range.start + indent_len + 1 + extra_indent
		closing_line := caret - range.start
		inserted[closing_line] = '\n'
		copy(inserted[closing_line + 1:], line.data[:indent_len])
	}
	operation: txn.Operation
	if range.start == range.end {
		operation = txn.Insert{pos = range.start, data = inserted}
	} else {
		operation = txn.Replace{range = range, data = inserted}
	}
	return apply_text_operation(doc, selection, operation, caret, grouping_key, allocator)
}

insert_committed_text :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	text: string,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	if !utf8.valid_string(text) {
		return errs.new(.Invalid_Input, "editing: IME commit is not valid UTF-8", allocator = allocator)
	}
	for r in text {
		if !valid_committed_rune(r) {
			return errs.new(.Invalid_Input, "editing: IME commit contains an invalid scalar", allocator = allocator)
		}
	}
	return insert_committed_bytes(doc, selection, transmute([]byte)text, grouping_key, allocator)
}

valid_committed_rune :: proc(text: rune) -> bool {
	return utf8.valid_rune(text) && text != 0 &&
		(text == '\n' || text == '\t' || text >= 0x20 && (text < 0x7f || text > 0x9f))
}

insert_committed_bytes :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	text: []byte,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	return insert_validated_bytes(doc, selection, text, grouping_key, allocator)
}

insert_validated_bytes :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	text: []byte,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	if len(text) == 0 {
		return {}
	}
	range := selection_range(selection^)
	caret := range.start + len(text)
	operation: txn.Operation
	if range.start == range.end {
		operation = txn.Insert{pos = range.start, data = text}
	} else {
		operation = txn.Replace{range = range, data = text}
	}
	return apply_text_operation(doc, selection, operation, caret, grouping_key, allocator)
}

delete_at_selection :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	direction: Step_Direction,
	allocator := context.allocator,
) -> errs.Error {
	if err := validate_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	range := selection_range(selection^)
	if range.start == range.end {
		target := selection.active
		if err := grapheme_step(&doc.tree, &target, direction, allocator); !errs.ok(err) {
			return err
		}
		if target == selection.active {
			return {}
		}
		range = {min(target, selection.active), max(target, selection.active)}
	} else if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	return apply_text_operation(doc, selection, txn.Delete{range = range}, range.start, 0, allocator)
}

delete_word_backward :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	allocator := context.allocator,
) -> errs.Error {
	if err := validate_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	range := selection_range(selection^)
	if range.start == range.end {
		target, err := word_left(&doc.tree, selection.active, allocator)
		if !errs.ok(err) {
			return err
		}
		if target == selection.active {
			return {}
		}
		range = {target, selection.active}
	} else if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	return apply_text_operation(doc, selection, txn.Delete{range = range}, range.start, 0, allocator)
}

apply_text_operation :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	operation: txn.Operation,
	caret: int,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	after := txn.Selection{anchor = caret, active = caret, affinity = .Left}
	ops := []txn.Operation{operation}
	return apply_text_operations(doc, selection, ops, after, grouping_key, allocator)
}

apply_text_operations :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	ops: []txn.Operation,
	after: txn.Selection,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	transaction := txn.Transaction {
		source = .Typing,
		base_revision = doc.revision,
		grouping_key = grouping_key,
		ops = ops,
		after_selection = after,
	}
	if err := txn.doc_apply(doc, &transaction, allocator); !errs.ok(err) {
		return err
	}
	selection^ = after
	return {}
}

validate_edit_selection :: proc(doc: ^txn.Doc, selection: txn.Selection, allocator := context.allocator) -> errs.Error {
	if err := validate_selection(doc, selection, allocator); !errs.ok(err) {
		return err
	}
	if err := validate_edit_caret(&doc.tree, selection.anchor, allocator); !errs.ok(err) {
		return err
	}
	if selection.active != selection.anchor {
		if err := validate_edit_caret(&doc.tree, selection.active, allocator); !errs.ok(err) {
			return err
		}
	}
	return {}
}

validate_edit_caret :: proc(tree: ^rope.Tree, offset: int, allocator := context.allocator) -> errs.Error {
	line, err := read_line_at(tree, offset, allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(line.data, allocator)
	if offset_err := validate_line_offset(line, offset, allocator); !errs.ok(offset_err) {
		return offset_err
	}
	_, column_err := grapheme_column(line, offset, allocator)
	return column_err
}
