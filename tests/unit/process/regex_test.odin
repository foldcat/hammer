package process_test

import "core:testing"

import process "hammer:core/process"
import txn "hammer:core/txn"

regex_test_set_result :: proc(search: ^process.Regex_Search, output: string) {
	copy(search.output[:], transmute([]byte)output)
	search.output_len = len(output)
	process.regex_search_ready(search)
}

@(test)
test_regex_search_applies_unicode_byte_range_without_editing :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&doc, transmute([]byte)string("αβ🙂 needle"), {}, context.allocator))
	defer txn.doc_destroy(&doc)
	search: process.Regex_Search
	expect_ok(t, process.regex_search_init(&search, &doc, {}, 11, 12, 13, context.allocator))
	defer process.regex_search_destroy(&search)
	testing.expect(t, string(search.input) == "αβ🙂 needle" && search.target.source_revision == txn.doc_revision(&doc))
	regex_test_set_result(&search, "9 15\n")
	revision := txn.doc_revision(&doc)
	match, err := process.regex_search_apply(&search, &doc, 11, 12, 13)
	expect_ok(t, err)
	testing.expect(t, match.start == 9 && match.end == 15)
	testing.expect(t, search.state == .Applied && txn.doc_revision(&doc) == revision)
}

@(test)
test_regex_search_rejects_stale_target_and_revision :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&doc, transmute([]byte)string("abc"), {}, context.allocator))
	defer txn.doc_destroy(&doc)
	search: process.Regex_Search
	expect_ok(t, process.regex_search_init(&search, &doc, {}, 11, 12, 13, context.allocator))
	defer process.regex_search_destroy(&search)
	regex_test_set_result(&search, "0 1\n")
	selection_test_edit(t, &doc, txn.Insert{pos = 3, data = transmute([]byte)string("d")})
	_, revision_err := process.regex_search_apply(&search, &doc, 11, 12, 13)
	expect_kind(t, revision_err, .Conflict)
	testing.expect(t, search.state == .Conflict)

	search.state = .Ready
	_, identity_err := process.regex_search_apply(&search, &doc, 11, 12, 14)
	expect_kind(t, identity_err, .Conflict)
	testing.expect(t, search.state == .Conflict)
}

@(test)
test_regex_search_rejects_invalid_results_and_utf8_boundaries :: proc(t: ^testing.T) {
	invalid := []string{"", "1\n", "1 2 3\n", "x 2\n", "3 2\n", "0 4\n", "-1 2\n"}
	for output in invalid {
		_, err := process.regex_search_parse_match(transmute([]byte)output, 3, context.allocator)
		expect_kind(t, err, .Invalid_Input)
	}
	match, err := process.regex_search_parse_match(transmute([]byte)string(" 0 3\n"), 3, context.allocator)
	expect_ok(t, err)
	testing.expect(t, match.start == 0 && match.end == 3)

	doc: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&doc, transmute([]byte)string("αx"), {}, context.allocator))
	defer txn.doc_destroy(&doc)
	search: process.Regex_Search
	expect_ok(t, process.regex_search_init(&search, &doc, {}, 11, 12, 13, context.allocator))
	defer process.regex_search_destroy(&search)
	regex_test_set_result(&search, "1 3\n")
	_, boundary_err := process.regex_search_apply(&search, &doc, 11, 12, 13)
	expect_kind(t, boundary_err, .Invalid_Input)
	testing.expect(t, search.state == .Failed)
}
