package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import txn "hammer:core/txn"

perform_indent :: proc(
	t: ^testing.T,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	direction: editing.Indent_Direction,
	settings: editing.Indent_Settings,
) {
	err := editing.indent(doc, selection, direction, settings)
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v: %v", direction, errs.describe(err))
}

@(test)
test_indent_multiline_is_one_undoable_transaction_and_preserves_direction :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "one\ntwo\nthree\nfour")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 11, active = 4, affinity = .Right, visual_column = 3}
	perform_indent(t, &doc, &selection, .Indent, {style = .Spaces, width = 2})
	expect_content(t, &doc, "one\n  two\n  three\nfour")
	testing.expect(t, selection == txn.Selection{anchor = 15, active = 4, affinity = .Right})
	testing.expect(t, txn.doc_log_len(&doc) == 1 && doc.log[0].source == .Indent)

	_, undo_err := txn.doc_undo(&doc)
	defer errs.destroy(&undo_err)
	testing.expect(t, errs.ok(undo_err))
	expect_content(t, &doc, "one\ntwo\nthree\nfour")
	redone, redo_err := txn.doc_redo(&doc)
	defer errs.destroy(&redo_err)
	testing.expect(t, errs.ok(redo_err))
	expect_content(t, &doc, "one\n  two\n  three\nfour")
	testing.expect(t, redone == selection)
}

@(test)
test_indent_excludes_selection_end_at_line_start :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "a\nb\nc\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 0, active = 2}
	settings := editing.Indent_Settings{style = .Tabs}
	perform_indent(t, &doc, &selection, .Indent, settings)
	expect_content(t, &doc, "\ta\nb\nc\n")
	testing.expect(t, selection.anchor == 0 && selection.active == 3)

	perform_indent(t, &doc, &selection, .Outdent, settings)
	expect_content(t, &doc, "a\nb\nc\n")
	testing.expect(t, selection.anchor == 0 && selection.active == 2)
	perform_indent(t, &doc, &selection, .Outdent, settings)
	expect_content(t, &doc, "a\nb\nc\n")
	testing.expect(t, txn.doc_revision(&doc) == 2 && txn.doc_log_len(&doc) == 2)
}

@(test)
test_outdent_removes_one_mixed_indentation_unit_per_line :: proc(t: ^testing.T) {
	original := "\tone\n  two\n    three\n      six\n\t four\nnone"
	want := "one\ntwo\nthree\n  six\n four\nnone"
	doc: txn.Doc
	doc_with_text(t, &doc, original)
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 0, active = len(original)}
	perform_indent(t, &doc, &selection, .Outdent, {style = .Spaces, width = 4})
	expect_content(t, &doc, want)
	testing.expect(t, selection.anchor == 0 && selection.active == len(want))
	testing.expect(t, txn.doc_log_len(&doc) == 1 && len(doc.log[0].ops) == 5)
}

@(test)
test_indent_and_outdent_with_collapsed_caret :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "ab")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	perform_indent(t, &doc, &selection, .Indent, {style = .Spaces, width = 2})
	expect_content(t, &doc, "a  b")
	testing.expect(t, selection == txn.Selection{anchor = 3, active = 3, affinity = .Left})
	selection.visual_column = 2
	perform_indent(t, &doc, &selection, .Outdent, {style = .Spaces, width = 2})
	expect_content(t, &doc, "a  b")
	testing.expect(t, selection == txn.Selection{anchor = 3, active = 3, affinity = .Left, visual_column = 2})
	testing.expect(t, txn.doc_revision(&doc) == 1 && txn.doc_log_len(&doc) == 1)

	indented: txn.Doc
	doc_with_text(t, &indented, "  ab")
	defer txn.doc_destroy(&indented)
	selection = {anchor = 4, active = 4}
	perform_indent(t, &indented, &selection, .Outdent, {style = .Spaces, width = 2})
	expect_content(t, &indented, "ab")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)

	tabbed: txn.Doc
	doc_with_text(t, &tabbed, "\tab")
	defer txn.doc_destroy(&tabbed)
	selection = {anchor = 2, active = 2}
	perform_indent(t, &tabbed, &selection, .Outdent, {style = .Tabs})
	expect_content(t, &tabbed, "ab")
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
}

@(test)
test_indent_blank_lines_and_crlf :: proc(t: ^testing.T) {
	original := "a\r\n\r\nb"
	indented := "\ta\r\n\t\r\n\tb"
	doc: txn.Doc
	doc_with_text(t, &doc, original)
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = len(original), active = 0, affinity = .Right}
	settings := editing.Indent_Settings{style = .Tabs}
	perform_indent(t, &doc, &selection, .Indent, settings)
	expect_content(t, &doc, indented)
	testing.expect(t, selection.anchor == len(indented) && selection.active == 0)
	perform_indent(t, &doc, &selection, .Outdent, settings)
	expect_content(t, &doc, original)
	testing.expect(t, selection.anchor == len(original) && selection.active == 0)
}

@(test)
test_indent_rejects_invalid_input_and_excessive_lines :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "A\u0301\nb")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	cases := []struct {
		direction: editing.Indent_Direction,
		settings:  editing.Indent_Settings,
	} {
		{direction = editing.Indent_Direction(99), settings = {}},
		{direction = .Indent, settings = {style = editing.Indent_Style(99)}},
		{direction = .Indent, settings = {width = -1}},
		{direction = .Indent, settings = {width = editing.MAX_INDENT_WIDTH + 1}},
	}
	for c in cases {
		err := editing.indent(&doc, &selection, c.direction, c.settings)
		expect_paste_error(t, err, .Invalid_Input)
		expect_content(t, &doc, "A\u0301\nb")
		testing.expect(t, selection == txn.Selection{} && txn.doc_log_len(&doc) == 0)
	}
	selection = {anchor = 1, active = 1}
	split_err := editing.indent(&doc, &selection, .Indent, {})
	expect_paste_error(t, split_err, .Invalid_Input)
	testing.expect(t, selection.anchor == 1 && selection.active == 1)

	data := make([]byte, editing.MAX_INDENT_LINES + 1)
	defer delete(data)
	for &b in data {
		b = '\n'
	}
	too_many: txn.Doc
	init_err := txn.doc_init_from_bytes(&too_many, data, {chunk_size = 32})
	defer errs.destroy(&init_err)
	testing.expect(t, errs.ok(init_err))
	defer txn.doc_destroy(&too_many)
	selection = {anchor = 0, active = len(data)}
	limit_err := editing.indent(&too_many, &selection, .Indent, {})
	expect_paste_error(t, limit_err, .Resource_Limit)
	testing.expect(t, selection.anchor == 0 && selection.active == len(data))
	testing.expect(t, txn.doc_revision(&too_many) == 0 && txn.doc_log_len(&too_many) == 0)
}
