package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import txn "hammer:core/txn"

perform_autopair_edit :: proc(t: ^testing.T, doc: ^txn.Doc, selection: ^txn.Selection, action: editing.Action) {
	err := editing.perform_with_options(doc, selection, action, {autopair = true, indent = {style = .Tabs}})
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v", errs.describe(err))
}

@(test)
test_autopair_newline_expands_pair_in_one_undo_step :: proc(t: ^testing.T) {
	cases := []struct {
		original: string,
		caret:    int,
		want:     string,
		after:    int,
	} {
		{original = "()", caret = 1, want = "(\n\t\n)", after = 3},
		{original = "[]", caret = 1, want = "[\n\t\n]", after = 3},
		{original = "{}", caret = 1, want = "{\n\t\n}", after = 3},
		{original = " \t{}", caret = 3, want = " \t{\n \t\t\n \t}", after = 7},
	}
	for c in cases {
		doc: txn.Doc
		doc_with_text(t, &doc, c.original)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{anchor = c.caret, active = c.caret}
		perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '\n', grouping_key = 7})
		expect_content(t, &doc, c.want)
		testing.expect(t, selection == txn.Selection{anchor = c.after, active = c.after, affinity = .Left})
		testing.expect(t, txn.doc_log_len(&doc) == 1 && len(doc.log[0].ops) == 1)

		restored, undo_err := txn.doc_undo(&doc)
		defer errs.destroy(&undo_err)
		testing.expect(t, errs.ok(undo_err))
		selection = restored
		expect_content(t, &doc, c.original)
		redone, redo_err := txn.doc_redo(&doc)
		defer errs.destroy(&redo_err)
		testing.expect(t, errs.ok(redo_err))
		testing.expect(t, redone == txn.Selection{anchor = c.after, active = c.after, affinity = .Left})
		expect_content(t, &doc, c.want)
	}
}

@(test)
test_autopair_newline_uses_configurable_indent_width :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "[]")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	err := editing.perform_with_options(
		&doc,
		&selection,
		editing.Insert_Text{text = '\n'},
		{autopair = true, indent = {style = .Spaces, width = 2}},
	)
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v", errs.describe(err))
	expect_content(t, &doc, "[\n  \n]")
	testing.expect(t, selection.anchor == 4 && selection.active == 4)
}

@(test)
test_autopair_newline_does_not_indent_nonbracket_or_disabled_pairs :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "\"\"")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '\n'})
	expect_content(t, &doc, "\"\n\"")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)

	literal: txn.Doc
	doc_with_text(t, &literal, "{}")
	defer txn.doc_destroy(&literal)
	selection = {anchor = 1, active = 1}
	perform_edit(t, &literal, &selection, editing.Insert_Text{text = '\n'})
	expect_content(t, &literal, "{\n}")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)
}

@(test)
test_autopair_delimiters_skip_close_and_delete_empty_pair :: proc(t: ^testing.T) {
	cases := []struct {
		open:  rune,
		close: rune,
		want:  string,
	} {
		{open = '(', close = ')', want = "()"},
		{open = '[', close = ']', want = "[]"},
		{open = '{', close = '}', want = "{}"},
		{open = '"', close = '"', want = "\"\""},
		{open = '\'', close = '\'', want = "''"},
		{open = '`', close = '`', want = "``"},
	}
	for c in cases {
		doc: txn.Doc
		doc_with_text(t, &doc, "")
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = c.open, grouping_key = 7})
		expect_content(t, &doc, c.want)
		testing.expect(t, selection == txn.Selection{anchor = 1, active = 1, affinity = .Left})
		testing.expect(t, txn.doc_log_len(&doc) == 1 && len(doc.log[0].ops) == 1)

		perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = c.close, grouping_key = 7})
		expect_content(t, &doc, c.want)
		testing.expect(t, selection.anchor == 2 && selection.active == 2)
		testing.expect(t, txn.doc_revision(&doc) == 1 && txn.doc_log_len(&doc) == 1)

		selection = {anchor = 1, active = 1, affinity = .Left}
		perform_autopair_edit(t, &doc, &selection, editing.Delete_Backward{})
		expect_content(t, &doc, "")
		testing.expect(t, selection == txn.Selection{})
		testing.expect(t, txn.doc_log_len(&doc) == 2 && len(doc.log[1].ops) == 1)
		restored, undo_err := txn.doc_undo(&doc)
		defer errs.destroy(&undo_err)
		testing.expect(t, errs.ok(undo_err))
		testing.expect(t, restored.anchor == 1 && restored.active == 1)
		expect_content(t, &doc, c.want)
	}
}

@(test)
test_autopair_wraps_reverse_selection_in_one_transaction :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 3, active = 0, affinity = .Right, visual_column = 2}
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '{'})
	expect_content(t, &doc, "{abc}")
	testing.expect(t, selection == txn.Selection{anchor = 4, active = 1, affinity = .Right})
	testing.expect(t, txn.doc_log_len(&doc) == 1 && len(doc.log[0].ops) == 2)
	testing.expect(t, doc.log[0].source == .Typing)

	_, undo_err := txn.doc_undo(&doc)
	defer errs.destroy(&undo_err)
	testing.expect(t, errs.ok(undo_err))
	expect_content(t, &doc, "abc")
	redone, redo_err := txn.doc_redo(&doc)
	defer errs.destroy(&redo_err)
	testing.expect(t, errs.ok(redo_err))
	testing.expect(t, redone == selection)
	expect_content(t, &doc, "{abc}")
}

@(test)
test_autopair_only_skips_an_adjacent_closing_delimiter :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '('})
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = 'x'})
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = ')'})
	expect_content(t, &doc, "(x)")
	testing.expect(t, selection.anchor == 3 && selection.active == 3)
	testing.expect(t, txn.doc_log_len(&doc) == 2)

	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = ')'})
	expect_content(t, &doc, "(x))")
	testing.expect(t, selection.anchor == 4 && selection.active == 4)
	testing.expect(t, txn.doc_log_len(&doc) == 3)
}

@(test)
test_autopair_disabled_preserves_literal_typing_and_backspace :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "()")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = ')'})
	expect_content(t, &doc, "())")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)

	selection = {anchor = 1, active = 1}
	perform_edit(t, &doc, &selection, editing.Delete_Backward{})
	expect_content(t, &doc, "))")
	testing.expect(t, selection == txn.Selection{})

	literal: txn.Doc
	doc_with_text(t, &literal, "")
	defer txn.doc_destroy(&literal)
	selection = {}
	perform_edit(t, &literal, &selection, editing.Insert_Text{text = '('})
	expect_content(t, &literal, "(")
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
}


@(test)
test_autopair_handles_single_scalar_commits_but_not_multiscalar_commits :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_autopair_edit(t, &doc, &selection, editing.Commit_Text{text = "["})
	expect_content(t, &doc, "[]")
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
	perform_autopair_edit(t, &doc, &selection, editing.Commit_Text{text = "]"})
	expect_content(t, &doc, "[]")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)
	testing.expect(t, txn.doc_log_len(&doc) == 1)

	perform_autopair_edit(t, &doc, &selection, editing.Commit_Text{text = "{}"})
	expect_content(t, &doc, "[]{}")
	testing.expect(t, selection.anchor == 4 && selection.active == 4)
	testing.expect(t, txn.doc_log_len(&doc) == 2 && len(doc.log[1].ops) == 1)
}


@(test)
test_autopair_reuses_unmatched_closer_across_lines :: proc(t: ^testing.T) {
	cases := []struct {
		open:     rune,
		original: string,
		want:     string,
	} {
		{open = '(', original = "one\ntwo)", want = "(one\ntwo)"},
		{open = '[', original = "one\ntwo]", want = "[one\ntwo]"},
		{open = '{', original = "one\ntwo}", want = "{one\ntwo}"},
	}
	for c in cases {
		doc: txn.Doc
		doc_with_text(t, &doc, c.original)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = c.open})
		expect_content(t, &doc, c.want)
		testing.expect(t, selection.anchor == 1 && selection.active == 1)
		inserted, ok := doc.log[0].ops[0].(txn.Insert)
		testing.expect(t, ok && len(inserted.data) == 1)
	}
}

@(test)
test_autopair_reuse_respects_balance_and_byte_order :: proc(t: ^testing.T) {
	cases := []struct {
		original:  string,
		caret:     int,
		want:      string,
		inserted:  int,
	} {
		{original = "())", caret = 1, want = "(())", inserted = 1},
		{original = "()", caret = 0, want = "()()", inserted = 2},
		{original = ")(", caret = 0, want = "()(", inserted = 1},
		{original = "(\n)", caret = 1, want = "(()\n)", inserted = 2},
	}
	for c in cases {
		doc: txn.Doc
		doc_with_text(t, &doc, c.original)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{anchor = c.caret, active = c.caret}
		perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '('})
		expect_content(t, &doc, c.want)
		inserted, ok := doc.log[0].ops[0].(txn.Insert)
		testing.expect(t, ok && len(inserted.data) == c.inserted)
	}
}

@(test)
test_autopair_multiline_scan_is_bounded :: proc(t: ^testing.T) {
	data := make([]byte, editing.MAX_AUTOPAIR_SCAN_LINES + 1)
	defer delete(data)
	for &b in data[:editing.MAX_AUTOPAIR_SCAN_LINES] {
		b = '\n'
	}
	data[editing.MAX_AUTOPAIR_SCAN_LINES] = ')'
	doc: txn.Doc
	doc_with_text(t, &doc, string(data))
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '('})
	inserted, ok := doc.log[0].ops[0].(txn.Insert)
	testing.expect(t, ok && len(inserted.data) == 2)
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
}

@(test)
test_autopair_quotes_remain_line_local :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "one\n'")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_autopair_edit(t, &doc, &selection, editing.Insert_Text{text = '\''})
	expect_content(t, &doc, "''one\n'")
	inserted, ok := doc.log[0].ops[0].(txn.Insert)
	testing.expect(t, ok && len(inserted.data) == 2)
}
