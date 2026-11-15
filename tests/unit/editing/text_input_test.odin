package editing_test

import "core:bytes"
import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

expect_content :: proc(t: ^testing.T, doc: ^txn.Doc, want: string) {
	got, err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)})
	defer delete(got)
	testing.expect(t, errs.ok(err))
	testing.expectf(t, bytes.equal(got, bytes_of(want)), "got %q, want %q", string(got), want)
	check_err := txn.doc_check(doc)
	defer errs.destroy(&check_err)
	testing.expect(t, errs.ok(check_err))
}

perform_edit :: proc(t: ^testing.T, doc: ^txn.Doc, selection: ^txn.Selection, action: editing.Action) {
	err := editing.perform(doc, selection, action)
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v", errs.describe(err))
}

@(test)
test_insert_unicode_replace_selection_and_special_scalars :: proc(t: ^testing.T) {
	doc := txn.Doc{}
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 2, active = 1, affinity = .Right, visual_column = 3}
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = '中'})
	expect_content(t, &doc, "a中c")
	testing.expect(t, selection == txn.Selection{anchor = 4, active = 4, affinity = .Left})
	testing.expect(t, txn.doc_revision(&doc) == 1)

	perform_edit(t, &doc, &selection, editing.Insert_Text{text = '\n'})
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = '\t'})
	expect_content(t, &doc, "a中\n\tc")
	testing.expect(t, selection.anchor == 6 && selection.active == 6)
	testing.expect(t, txn.doc_log_len(&doc) == 3)
}

@(test)
test_consecutive_insert_group_is_one_undo_step :: proc(t: ^testing.T) {
	doc := txn.Doc{}
	doc_with_text(t, &doc, "")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'a', grouping_key = 7})
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = '中', grouping_key = 7})
	expect_content(t, &doc, "a中")
	testing.expect(t, txn.doc_log_len(&doc) == 2)

	restored, undo_err := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(undo_err))
	testing.expect(t, restored == txn.Selection{})
	selection = restored
	expect_content(t, &doc, "")
	redo_selection, redo_err := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(redo_err))
	selection = redo_selection
	expect_content(t, &doc, "a中")
	testing.expect(t, selection.anchor == 4 && selection.active == 4)
}

@(test)
test_backspace_delete_and_selection_delete_use_graphemes :: proc(t: ^testing.T) {
	doc := txn.Doc{}
	doc_with_text(t, &doc, "A\u0301👩\u200d💻B")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 15, active = 15}
	perform_edit(t, &doc, &selection, editing.Delete_Backward{})
	expect_content(t, &doc, "A\u0301👩\u200d💻")
	testing.expect(t, selection.anchor == 14 && selection.active == 14)
	perform_edit(t, &doc, &selection, editing.Delete_Backward{})
	expect_content(t, &doc, "A\u0301")
	testing.expect(t, selection.anchor == 3 && selection.active == 3)
	selection = {}
	perform_edit(t, &doc, &selection, editing.Delete_Forward{})
	expect_content(t, &doc, "")
	testing.expect(t, selection == txn.Selection{anchor = 0, active = 0, affinity = .Left})
	perform_edit(t, &doc, &selection, editing.Delete_Backward{})
	perform_edit(t, &doc, &selection, editing.Delete_Forward{})
	testing.expect(t, txn.doc_log_len(&doc) == 3)

	selected := txn.Doc{}
	doc_with_text(t, &selected, "abc")
	defer txn.doc_destroy(&selected)
	selection = {anchor = 2, active = 1}
	perform_edit(t, &selected, &selection, editing.Delete_Forward{})
	expect_content(t, &selected, "ac")
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
}

@(test)
test_invalid_text_and_split_caret_change_nothing :: proc(t: ^testing.T) {
	doc := txn.Doc{}
	doc_with_text(t, &doc, "A\u0301")
	defer txn.doc_destroy(&doc)
	invalid_runes := []rune{0, '\r', rune(1), rune(0x7f), rune(0x85), rune(0xd800), rune(0x110000)}
	for invalid in invalid_runes {
		selection := txn.Selection{}
		err := editing.perform(&doc, &selection, editing.Insert_Text{text = invalid})
		testing.expect(t, err.kind == .Invalid_Input)
		errs.destroy(&err)
		expect_content(t, &doc, "A\u0301")
		testing.expect(t, selection == txn.Selection{})
		testing.expect(t, txn.doc_revision(&doc) == 0 && txn.doc_log_len(&doc) == 0)
	}

	selection := txn.Selection{anchor = 1, active = 1}
	err := editing.perform(&doc, &selection, editing.Insert_Text{text = 'x'})
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	expect_content(t, &doc, "A\u0301")
	testing.expect(t, selection.anchor == 1 && selection.active == 1)
	testing.expect(t, txn.doc_revision(&doc) == 0 && txn.doc_log_len(&doc) == 0)
}
