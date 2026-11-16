package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import txn "hammer:core/txn"

expect_cut_error :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got %v, want %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

apply_cut_test_operation :: proc(t: ^testing.T, doc: ^txn.Doc, operation: txn.Operation) {
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
test_delayed_cut_deletes_captured_selection_after_write_success :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abcd")
	defer txn.doc_destroy(&doc)
	other: txn.Doc
	doc_with_text(t, &other, "focused")
	defer txn.doc_destroy(&other)

	selection := txn.Selection{anchor = 3, active = 1, affinity = .Right, visual_column = 3}
	cut: editing.Delayed_Cut
	begin_err := editing.delayed_cut_begin(&cut, &doc, &selection, 10, 4, 99)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	testing.expect(t, cut.pending)
	testing.expect(t, cut.target.buffer_id == 10 && cut.target.generation == 4)
	testing.expect(t, cut.target.request_id == 99 && cut.target.source_revision == 0)
	expect_content(t, &doc, "abcd")

	selection = {}
	apply_err := editing.delayed_cut_apply(&cut, &doc, &selection, 10, 4, 99)
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "ad")
	expect_content(t, &other, "focused")
	testing.expect(t, selection == txn.Selection{anchor = 1, active = 1, affinity = .Left})
	testing.expect(t, !cut.pending)
	testing.expect(t, txn.doc_log_len(&doc) == 1 && doc.log[0].source == .Cut)
}

@(test)
test_delayed_cut_transforms_selection_through_intervening_edits :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abcdef")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 4, active = 2, affinity = .Right}
	cut: editing.Delayed_Cut
	begin_err := editing.delayed_cut_begin(&cut, &doc, &selection, 1, 1, 1)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))

	apply_cut_test_operation(t, &doc, txn.Insert{pos = 0, data = bytes_of("XX")})
	apply_err := editing.delayed_cut_apply(&cut, &doc, &selection, 1, 1, 1)
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "XXabef")
	testing.expect(t, selection.anchor == 4 && selection.active == 4)
	testing.expect(t, txn.doc_revision(&doc) == 2)
}

@(test)
test_delayed_cut_rejects_mismatched_cancelled_and_duplicate_results :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 0, active = 2}
	cut: editing.Delayed_Cut
	begin_err := editing.delayed_cut_begin(&cut, &doc, &selection, 7, 11, 40)
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
		err := editing.delayed_cut_apply(
			&cut,
			&doc,
			&selection,
			mismatch.buffer_id,
			mismatch.generation,
			mismatch.request_id,
		)
		expect_cut_error(t, err, .Conflict)
		testing.expect(t, cut.pending)
		expect_content(t, &doc, "abc")
	}

	apply_err := editing.delayed_cut_apply(&cut, &doc, &selection, 7, 11, 40)
	defer errs.destroy(&apply_err)
	testing.expect(t, errs.ok(apply_err))
	expect_content(t, &doc, "c")
	duplicate_err := editing.delayed_cut_apply(&cut, &doc, &selection, 7, 11, 40)
	expect_cut_error(t, duplicate_err, .Conflict)
	expect_content(t, &doc, "c")

	selection = txn.Selection{anchor = 0, active = 1}
	restart_err := editing.delayed_cut_begin(&cut, &doc, &selection, 7, 11, 41)
	defer errs.destroy(&restart_err)
	testing.expect(t, errs.ok(restart_err))
	wrong_cancel := editing.delayed_cut_cancel(&cut, 40)
	expect_cut_error(t, wrong_cancel, .Conflict)
	testing.expect(t, cut.pending)
	cancel_err := editing.delayed_cut_cancel(&cut, 41)
	defer errs.destroy(&cancel_err)
	testing.expect(t, errs.ok(cancel_err))
	late_err := editing.delayed_cut_apply(&cut, &doc, &selection, 7, 11, 41)
	expect_cut_error(t, late_err, .Conflict)
	expect_content(t, &doc, "c")
}

@(test)
test_delayed_cut_rejects_abandoned_source_revision :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'a'})
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'b'})
	selection = txn.Selection{anchor = 1, active = 3}
	cut: editing.Delayed_Cut
	begin_err := editing.delayed_cut_begin(&cut, &doc, &selection, 5, 6, 12)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	testing.expect(t, cut.target.source_revision == 2)

	restored, undo_err := txn.doc_undo(&doc)
	defer errs.destroy(&undo_err)
	testing.expect(t, errs.ok(undo_err))
	selection = restored
	perform_edit(t, &doc, &selection, editing.Insert_Text{text = 'c'})
	before := selection
	apply_err := editing.delayed_cut_apply(&cut, &doc, &selection, 5, 6, 12)
	expect_cut_error(t, apply_err, .Conflict)
	expect_content(t, &doc, "acabc")
	testing.expect(t, selection == before)
	testing.expect(t, !cut.pending)
}

@(test)
test_delayed_cut_invalid_input_changes_nothing :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	cut: editing.Delayed_Cut
	empty_err := editing.delayed_cut_begin(&cut, &doc, &selection, 1, 1, 1)
	expect_cut_error(t, empty_err, .Invalid_Input)
	testing.expect(t, !cut.pending)

	selection = txn.Selection{anchor = 0, active = 1}
	id_err := editing.delayed_cut_begin(&cut, &doc, &selection, 0, 1, 1)
	expect_cut_error(t, id_err, .Invalid_Input)
	request_err := editing.delayed_cut_begin(&cut, &doc, &selection, 1, 1, 0)
	expect_cut_error(t, request_err, .Invalid_Input)
	begin_err := editing.delayed_cut_begin(&cut, &doc, &selection, 1, 1, 1)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	missing_err := editing.delayed_cut_apply(&cut, nil, &selection, 1, 1, 1)
	expect_cut_error(t, missing_err, .Invalid_Input)
	testing.expect(t, !cut.pending)
	expect_content(t, &doc, "abc")
	testing.expect(t, selection == txn.Selection{anchor = 0, active = 1})
}
