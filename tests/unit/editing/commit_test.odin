package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import txn "hammer:core/txn"

@(test)
test_ime_commit_is_one_atomic_unicode_transaction :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "ab")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 0, affinity = .Right}
	perform_edit(t, &doc, &selection, editing.Commit_Text{text = "é中🙂", grouping_key = 7})
	expect_content(t, &doc, "é中🙂b")
	testing.expect(t, selection == txn.Selection{anchor = 9, active = 9, affinity = .Left})
	testing.expect(t, txn.doc_log_len(&doc) == 1 && doc.log[0].source == .Typing)

	_, undo_err := txn.doc_undo(&doc)
	defer errs.destroy(&undo_err)
	testing.expect(t, errs.ok(undo_err))
	expect_content(t, &doc, "ab")
	redone, redo_err := txn.doc_redo(&doc)
	defer errs.destroy(&redo_err)
	testing.expect(t, errs.ok(redo_err))
	expect_content(t, &doc, "é中🙂b")
	testing.expect(t, redone == selection)
}

@(test)
test_ime_commit_rejects_invalid_text_and_empty_is_noop :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 2, active = 1, affinity = .Right, visual_column = 2}
	perform_edit(t, &doc, &selection, editing.Commit_Text{})
	expect_content(t, &doc, "abc")
	testing.expect(t, selection == txn.Selection{anchor = 2, active = 1, affinity = .Right, visual_column = 2})
	testing.expect(t, txn.doc_revision(&doc) == 0 && txn.doc_log_len(&doc) == 0)

	invalid_bytes := []byte{0xff}
	invalid_utf8 := string(invalid_bytes)
	invalid := []editing.Commit_Text {
		{text = invalid_utf8},
		{text = "a\x00b"},
		{text = "a\rb"},
		{text = "a\x01b"},
	}
	for commit in invalid {
		err := editing.perform(&doc, &selection, commit)
		expect_paste_error(t, err, .Invalid_Input)
		expect_content(t, &doc, "abc")
		testing.expect(t, selection.anchor == 2 && selection.active == 1)
		testing.expect(t, txn.doc_revision(&doc) == 0 && txn.doc_log_len(&doc) == 0)
	}
}
