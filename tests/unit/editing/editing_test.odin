package editing_test

import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

bytes_of :: proc(text: string) -> []byte {
	return transmute([]byte)text
}

doc_with_text :: proc(t: ^testing.T, doc: ^txn.Doc, text: string) {
	init_err := txn.doc_init_from_bytes(doc, bytes_of(text), {chunk_size = 4})
	testing.expect(t, errs.ok(init_err))
}

expect_move :: proc(
	t: ^testing.T,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	motion: editing.Motion,
	extend: bool,
	want_anchor: int,
	want_active: int,
) {
	err := editing.perform(doc, selection, editing.Move{motion = motion, extend = extend})
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v: %v", motion, errs.describe(err))
	testing.expectf(
		t,
		selection.anchor == want_anchor && selection.active == want_active,
		"%v: got selection [%v, %v], want [%v, %v]",
		motion,
		selection.anchor,
		selection.active,
		want_anchor,
		want_active,
	)
	testing.expect(t, txn.doc_revision(doc) == 0)
	testing.expect(t, txn.doc_log_len(doc) == 0)
}

@(test)
test_grapheme_motion_and_selection_direction :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "A\u0301👩\u200d💻B\nsecond\r\nthird")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{affinity = .Right}
	boundaries := []int{0, 3, 14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 25, 26, 27, 28, 29}
	for want in boundaries[1:] {
		expect_move(t, &doc, &selection, .Grapheme_Right, false, want, want)
	}
	testing.expect(t, selection.affinity == .Right)
	for index := len(boundaries) - 2; index >= 0; index -= 1 {
		want := boundaries[index]
		expect_move(t, &doc, &selection, .Grapheme_Left, false, want, want)
	}

	expect_move(t, &doc, &selection, .Grapheme_Right, true, 0, 3)
	expect_move(t, &doc, &selection, .Grapheme_Right, true, 0, 14)
	expect_move(t, &doc, &selection, .Grapheme_Left, false, 0, 0)
	expect_move(t, &doc, &selection, .Grapheme_Right, false, 3, 3)
	expect_move(t, &doc, &selection, .Grapheme_Right, true, 3, 14)
	expect_move(t, &doc, &selection, .Grapheme_Left, true, 3, 3)
	expect_move(t, &doc, &selection, .Grapheme_Left, true, 3, 0)
	testing.expect(t, editing.selection_range(selection) == rope.Byte_Range{0, 3})
}

@(test)
test_line_boundaries_and_crlf :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "one\r\ntwo\rthree\nfour")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 7, active = 7}
	expect_move(t, &doc, &selection, .Line_Start, false, 5, 5)
	expect_move(t, &doc, &selection, .Line_End, false, 8, 8)
	expect_move(t, &doc, &selection, .Line_Start, true, 8, 5)
	selection = {anchor = 7, active = 7, affinity = .Right}
	expect_move(t, &doc, &selection, .Line_End, true, 7, 8)
	testing.expect(t, selection.affinity == .Right)
	expect_move(t, &doc, &selection, .Document_Start, false, 0, 0)
	expect_move(t, &doc, &selection, .Document_End, false, 19, 19)
}

@(test)
test_vertical_motion_preserves_preferred_grapheme_column :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abcd\nxy\nA\u0301bc\n12345")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 3, active = 3}
	expect_move(t, &doc, &selection, .Line_Down, false, 7, 7)
	testing.expect(t, selection.visual_column == 3)
	expect_move(t, &doc, &selection, .Line_Down, false, 13, 13)
	expect_move(t, &doc, &selection, .Line_Down, false, 17, 17)
	expect_move(t, &doc, &selection, .Line_Down, false, 17, 17)
	expect_move(t, &doc, &selection, .Line_Up, false, 13, 13)
	expect_move(t, &doc, &selection, .Line_Up, false, 7, 7)
	expect_move(t, &doc, &selection, .Line_Up, false, 3, 3)
	expect_move(t, &doc, &selection, .Line_Up, false, 3, 3)

	selection = {anchor = 11, active = 11}
	expect_move(t, &doc, &selection, .Line_Up, false, 6, 6)
	testing.expect(t, selection.visual_column == 1)
	expect_move(t, &doc, &selection, .Line_Down, true, 6, 11)
	testing.expect(t, editing.selection_range(selection) == rope.Byte_Range{6, 11})
}

@(test)
test_word_motion_unicode_and_line_crossing :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "one,two 中\nthree")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	right_targets := []int{4, 8, 12, 17, 17}
	for want in right_targets {
		expect_move(t, &doc, &selection, .Word_Right, false, want, want)
	}
	left_targets := []int{12, 8, 4, 0, 0}
	for want in left_targets {
		expect_move(t, &doc, &selection, .Word_Left, false, want, want)
	}
	selection = {anchor = 2, active = 2}
	expect_move(t, &doc, &selection, .Word_Left, false, 0, 0)
	selection = {anchor = 2, active = 2}
	expect_move(t, &doc, &selection, .Word_Right, false, 4, 4)
	selection = {anchor = 2, active = 2}
	expect_move(t, &doc, &selection, .Word_Right, true, 2, 4)
	expect_move(t, &doc, &selection, .Word_Left, true, 2, 0)

	combining: txn.Doc
	doc_with_text(t, &combining, "e\u0301lan next")
	defer txn.doc_destroy(&combining)
	selection = {anchor = 3, active = 3}
	expect_move(t, &combining, &selection, .Word_Left, false, 0, 0)
	selection = {anchor = 3, active = 3}
	expect_move(t, &combining, &selection, .Word_Right, false, 7, 7)
}

@(test)
test_select_all_action :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "abc\ndef")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{anchor = 5, active = 2, affinity = .Right, visual_column = 4}
	err := editing.perform(&doc, &selection, editing.Select_All{})
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	testing.expect(t, selection.anchor == 0 && selection.active == 7)
	testing.expect(t, selection.affinity == .Right && selection.visual_column == 0)
	testing.expect(t, editing.selection_range(selection) == rope.Byte_Range{0, 7})
	expect_move(t, &doc, &selection, .Grapheme_Left, false, 0, 0)
}

@(test)
test_empty_document_and_horizontal_preference_reset :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	motions := []editing.Motion{
		.Grapheme_Left,
		.Grapheme_Right,
		.Word_Left,
		.Word_Right,
		.Line_Up,
		.Line_Down,
		.Line_Start,
		.Line_End,
		.Document_Start,
		.Document_End,
	}
	for motion in motions {
		expect_move(t, &doc, &selection, motion, false, 0, 0)
	}

	with_text: txn.Doc
	doc_with_text(t, &with_text, "ab\ncd")
	defer txn.doc_destroy(&with_text)
	selection = {anchor = 1, active = 1, visual_column = 1}
	expect_move(t, &with_text, &selection, .Grapheme_Right, false, 2, 2)
	testing.expect(t, selection.visual_column == 0)
}

@(test)
test_invalid_selection_and_grapheme_offsets :: proc(t: ^testing.T) {
	doc: txn.Doc
	doc_with_text(t, &doc, "A\u0301\nb")
	defer txn.doc_destroy(&doc)
	cases := []struct {
		selection: txn.Selection,
		motion:    editing.Motion,
	} {
		{{anchor = 0, active = 9}, .Grapheme_Right},
		{{anchor = 1, active = 1}, .Grapheme_Right},
		{{anchor = 1, active = 1}, .Word_Left},
		{{anchor = 1, active = 1}, .Line_Down},
		{{anchor = 0, active = 0, visual_column = -1}, .Line_Down},
		{{anchor = 0, active = 0, visual_column = 0.5}, .Line_Down},
	}
	for c in cases {
		selection := c.selection
		err := editing.move(&doc, &selection, c.motion, false)
		testing.expectf(t, err.kind == .Invalid_Input, "%v: got %v", c.motion, err.kind)
		errs.destroy(&err)
		testing.expect(t, selection == c.selection)
		testing.expect(t, txn.doc_revision(&doc) == 0 && txn.doc_log_len(&doc) == 0)
	}
}

@(test)
test_oversized_line_is_bounded :: proc(t: ^testing.T) {
	data := make([]byte, editing.MAX_LINE_BYTES + 1)
	defer delete(data)
	for &b in data {
		b = 'a'
	}
	doc: txn.Doc
	init_err := txn.doc_init_from_bytes(&doc, data, {})
	testing.expect(t, errs.ok(init_err))
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := editing.move(&doc, &selection, .Grapheme_Right, false)
	testing.expect(t, err.kind == .Resource_Limit)
	errs.destroy(&err)
	testing.expect(t, selection == txn.Selection{})
	expect_move(t, &doc, &selection, .Document_End, false, len(data), len(data))
}
