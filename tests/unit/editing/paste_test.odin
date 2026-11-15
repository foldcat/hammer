package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import txn "hammer:core/txn"

expect_paste_error :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got %v, want %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

apply_paste_test_operation :: proc(t: ^testing.T, doc: ^txn.Doc, operation: txn.Operation) {
	ops := []txn.Operation{operation}
	transaction := txn.Transaction {
		source = .Edit,
		base_revision = txn.doc_revision(doc),
		ops = ops,
		after_selection = {},
	}
	err := txn.doc_apply(doc, &transaction)
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v", errs.describe(err))
}

@(test)
test_delayed_paste_uses_captured_target_and_selection :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abcd")
	defer txn.doc_destroy(&doc)
	other: txn.Doc
	doc_with_text(t, &other, "focused")
	defer txn.doc_destroy(&other)

	selection := txn.Selection{anchor = 3, active = 1, affinity = .Right, visual_column = 3}
	paste: editing.Delayed_Paste
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 10, 4, 99)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	testing.expect(t, paste.pending)
	testing.expect(t, paste.target.buffer_id == 10 && paste.target.generation == 4)
	testing.expect(t, paste.target.request_id == 99 && paste.target.source_revision == 0)
	testing.expect(t, paste.target.anchor.pos == 3 && paste.target.active.pos == 1)

	selection = {}
	apply_err := editing.delayed_paste_apply(&paste, &doc, &selection, 10, 4, 99, bytes_of("中🙂"))
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "a中🙂d")
	expect_content(t, &other, "focused")
	testing.expect(t, selection == txn.Selection{anchor = 8, active = 8, affinity = .Left})
	testing.expect(t, !paste.pending)
	testing.expect(t, txn.doc_log_len(&doc) == 1 && doc.log[0].source == .Paste)
}

@(test)
test_delayed_paste_transforms_selection_through_intervening_edits :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abcdef")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 4, active = 2, affinity = .Right}
	paste: editing.Delayed_Paste
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 1, 1, 1)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))

	apply_paste_test_operation(t, &doc, txn.Insert{pos = 0, data = bytes_of("XX")})
	apply_err := editing.delayed_paste_apply(&paste, &doc, &selection, 1, 1, 1, bytes_of("Z"))
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "XXabZef")
	testing.expect(t, selection.anchor == 5 && selection.active == 5)
	testing.expect(t, txn.doc_revision(&doc) == 2)
}

@(test)
test_delayed_paste_rejects_mismatched_and_duplicate_results :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	paste: editing.Delayed_Paste
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 7, 11, 40)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))

	mismatches := []struct {
		buffer_id:  u64,
		generation: u64,
		request_id: u64,
	} {
		{buffer_id = 8, generation = 11, request_id = 40},
		{buffer_id = 7, generation = 12, request_id = 40},
		{buffer_id = 7, generation = 11, request_id = 41},
	}
	for mismatch in mismatches {
		err := editing.delayed_paste_apply(
			&paste,
			&doc,
			&selection,
			mismatch.buffer_id,
			mismatch.generation,
			mismatch.request_id,
			bytes_of("bad"),
		)
		expect_paste_error(t, err, .Conflict)
		testing.expect(t, paste.pending)
		expect_content(t, &doc, "abc")
		testing.expect(t, selection == txn.Selection{anchor = 1, active = 1})
	}

	apply_err := editing.delayed_paste_apply(&paste, &doc, &selection, 7, 11, 40, bytes_of("X"))
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "aXbc")
	duplicate_err := editing.delayed_paste_apply(&paste, &doc, &selection, 7, 11, 40, bytes_of("X"))
	expect_paste_error(t, duplicate_err, .Conflict)
	expect_content(t, &doc, "aXbc")
	testing.expect(t, selection.anchor == 2 && selection.active == 2)
}

@(test)
test_delayed_paste_cancel_rejects_late_result :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "original")
	defer txn.doc_destroy(&doc)
	focused: txn.Doc
	doc_with_text(t, &focused, "focused")
	defer txn.doc_destroy(&focused)
	selection := txn.Selection{}
	focused_selection := txn.Selection{}
	paste: editing.Delayed_Paste
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 3, 2, 8)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))

	wrong_cancel := editing.delayed_paste_cancel(&paste, 9)
	expect_paste_error(t, wrong_cancel, .Conflict)
	testing.expect(t, paste.pending)
	cancel_err := editing.delayed_paste_cancel(&paste, 8)
	defer errs.destroy(&cancel_err)
	testing.expect(t, errs.ok(cancel_err))
	testing.expect(t, !paste.pending)

	late_err := editing.delayed_paste_apply(&paste, &focused, &focused_selection, 3, 2, 8, bytes_of("late"))
	expect_paste_error(t, late_err, .Conflict)
	expect_content(t, &doc, "original")
	expect_content(t, &focused, "focused")
}

@(test)
test_delayed_paste_rejects_abandoned_source_revision :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'a'})
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'b'})
	paste: editing.Delayed_Paste
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 5, 6, 12)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	testing.expect(t, paste.target.source_revision == 2)

	restored, undo_err := txn.doc_undo(&doc)
	defer errs.destroy(&undo_err)
	testing.expect(t, errs.ok(undo_err))
	selection = restored
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'c'})
	before := selection
	apply_err := editing.delayed_paste_apply(&paste, &doc, &selection, 5, 6, 12, bytes_of("stale"))
	expect_paste_error(t, apply_err, .Conflict)
	expect_content(t, &doc, "acabc")
	testing.expect(t, selection == before)
	testing.expect(t, !paste.pending)
}

@(test)
test_delayed_paste_invalid_input_changes_nothing :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "A\u0301")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 1, active = 1}
	paste: editing.Delayed_Paste
	capture_err := editing.delayed_paste_begin(&paste, &doc, &selection, 1, 1, 1)
	expect_paste_error(t, capture_err, .Invalid_Input)
	testing.expect(t, !paste.pending)

	selection = {}
	id_err := editing.delayed_paste_begin(&paste, &doc, &selection, 0, 1, 1)
	expect_paste_error(t, id_err, .Invalid_Input)
	request_err := editing.delayed_paste_begin(&paste, &doc, &selection, 1, 1, 0)
	expect_paste_error(t, request_err, .Invalid_Input)
	begin_err := editing.delayed_paste_begin(&paste, &doc, &selection, 1, 1, 1)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))

	invalid_utf8 := []byte{0xff, 'x'}
	apply_err := editing.delayed_paste_apply(&paste, &doc, &selection, 1, 1, 1, invalid_utf8)
	expect_paste_error(t, apply_err, .Invalid_Input)
	expect_content(t, &doc, "A\u0301")
	testing.expect(t, selection == txn.Selection{})
	testing.expect(t, !paste.pending && txn.doc_log_len(&doc) == 0)

	restart_err := editing.delayed_paste_begin(&paste, &doc, &selection, 1, 1, 2)
	defer errs.destroy(&restart_err)
	testing.expect(t, errs.ok(restart_err))
	missing_err := editing.delayed_paste_apply(&paste, nil, &selection, 1, 1, 2, bytes_of("x"))
	expect_paste_error(t, missing_err, .Invalid_Input)
	testing.expect(t, !paste.pending)
	expect_content(t, &doc, "A\u0301")
}
