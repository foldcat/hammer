package mouse_test

import "core:testing"

import errs "hammer:core/errs"
import mouse "hammer:core/mouse"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

init_doc :: proc(t: ^testing.T, doc: ^txn.Doc, text: string, chunk_size := 4) {
	testing.expect(t, errs.ok(txn.doc_init_from_bytes(doc, transmute([]byte)text, {chunk_size = chunk_size})))
}

expect_range :: proc(t: ^testing.T, got: rope.Byte_Range, start, end: int) {
	testing.expectf(t, got.start == start && got.end == end, "got [%d, %d), want [%d, %d)", got.start, got.end, start, end)
}

expect_text :: proc(t: ^testing.T, doc: ^txn.Doc, range: rope.Byte_Range, want: string) {
	data, err := mouse.read_action_text(doc, range)
	defer delete(data)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	testing.expectf(t, string(data) == want, "got %q, want %q", string(data), want)
}

@(test)
test_execute_expansion_and_existing_selection :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "xx Put yy a:b")
	defer txn.doc_destroy(&doc)

	range, err := mouse.action_range(&doc, {}, 3, 3, .Execute)
	testing.expect(t, errs.ok(err))
	expect_range(t, range, 3, 6)
	expect_text(t, &doc, range, "Put")

	selection := txn.Selection{anchor = 0, active = 6}
	range, err = mouse.action_range(&doc, selection, 3, 3, .Execute)
	testing.expect(t, errs.ok(err))
	expect_range(t, range, 0, 6)

	range, err = mouse.action_range(&doc, {}, 10, 10, .Execute)
	testing.expect(t, errs.ok(err))
	expect_text(t, &doc, range, "a")
	range, err = mouse.action_range(&doc, {}, 10, 10, .Look)
	testing.expect(t, errs.ok(err))
	expect_text(t, &doc, range, "a:b")
}

@(test)
test_double_click_word_pair_line_and_unicode :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "(one [two])\n中 word\n")
	defer txn.doc_destroy(&doc)

	range, err := mouse.double_click_range(&doc, 2)
	testing.expect(t, errs.ok(err))
	expect_range(t, range, 1, 4)
	range, err = mouse.double_click_range(&doc, 1)
	testing.expect(t, errs.ok(err))
	expect_range(t, range, 1, 10)
	range, err = mouse.double_click_range(&doc, 15)
	testing.expect(t, errs.ok(err))
	expect_text(t, &doc, range, "中")
	range, err = mouse.double_click_range(&doc, 12)
	testing.expect(t, errs.ok(err))
	expect_text(t, &doc, range, "中 word")
}

@(test)
test_literal_search_wrap_reverse_and_chunks :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "alpha beta alpha\nalpha", 2)
	defer txn.doc_destroy(&doc)
	needle := transmute([]byte)string("alpha")

	range, found, err := mouse.find_literal(&doc, needle, 6, false)
	testing.expect(t, errs.ok(err) && found)
	expect_range(t, range, 11, 16)
	range, found, err = mouse.find_literal(&doc, needle, 22, false)
	testing.expect(t, errs.ok(err) && found)
	expect_range(t, range, 0, 5)
	range, found, err = mouse.find_literal(&doc, needle, 11, true)
	testing.expect(t, errs.ok(err) && found)
	expect_range(t, range, 0, 5)
	range, found, err = mouse.find_literal(&doc, needle, 0, true)
	testing.expect(t, errs.ok(err) && found)
	expect_range(t, range, 17, 22)
	_, found, err = mouse.find_literal(&doc, transmute([]byte)string("missing"), 0, false)
	testing.expect(t, errs.ok(err) && !found)
	_, found, err = mouse.find_literal(&doc, needle, 23, false)
	testing.expect(t, !errs.ok(err) && err.kind == .Invalid_Input && !found)
	errs.destroy(&err)
}

@(test)
test_token_budget_is_explicit :: proc(t: ^testing.T) {
	data, alloc_err := make([]byte, mouse.MAX_TOKEN_SCAN_BYTES + 2)
	testing.expect(t, alloc_err == .None)
	defer delete(data)
	for index in 0 ..< len(data) {
		data[index] = 'a'
	}
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init_from_bytes(&doc, data, {})))
	defer txn.doc_destroy(&doc)
	_, err := mouse.expand_token(&doc, mouse.MAX_TOKEN_SCAN_BYTES, .Execute)
	testing.expect(t, !errs.ok(err) && err.kind == .Resource_Limit)
	errs.destroy(&err)
}


@(test)
test_look_path_and_windows_token_expansion :: proc(t: ^testing.T) {
	reference := mouse.parse_look_path("target.txt")
	testing.expect(t, reference.path == "target.txt" && reference.line == 0)
	reference = mouse.parse_look_path("target.txt:12")
	testing.expect(t, reference.path == "target.txt" && reference.line == 12)
	reference = mouse.parse_look_path(`C:\work\target.txt:9`)
	testing.expect(t, reference.path == `C:\work\target.txt` && reference.line == 9)
	reference = mouse.parse_look_path("relative.txt:001")
	testing.expect(t, reference.path == "relative.txt" && reference.line == 1)
	unchanged := []string{"target.txt:", ":2", "target.txt:0", "target.txt:x", "target.txt:999999999999999999999999999"}
	for text in unchanged {
		reference = mouse.parse_look_path(text)
		testing.expect(t, reference.path == text && reference.line == 0)
	}

	doc: txn.Doc
	init_doc(t, &doc, `xx C:\work\target.txt:9 yy`)
	defer txn.doc_destroy(&doc)
	range, err := mouse.action_range(&doc, {}, 6, 6, .Look)
	testing.expect(t, errs.ok(err))
	expect_text(t, &doc, range, `C:\work\target.txt:9`)
}
