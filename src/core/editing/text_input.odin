package editing

import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"
import txn "../txn"

// Insert_Text replaces the current selection with one Unicode scalar. A shared
// nonzero grouping_key joins consecutive typing transactions into one undo unit.
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
	encoded, width := utf8.encode_rune(text)
	return insert_committed_bytes(doc, selection, encoded[:width], grouping_key, allocator)
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
