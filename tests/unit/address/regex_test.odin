package address_test

import "core:sync"
import "core:testing"

import address "hammer:core/address"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

expect_range_history :: proc(
	t: ^testing.T,
	doc: ^txn.Doc,
	text: string,
	dot: rope.Byte_Range,
	history: ^address.Regex_History,
	want: rope.Byte_Range,
) {
	expression, parse_err := address.parse(text, context.allocator)
	if !errs.ok(parse_err) {
		testing.expectf(t, false, "parse %q failed: %v", text, parse_err.message)
		errs.destroy(&parse_err)
		return
	}
	got, eval_err := address.evaluate_with_history(&doc.tree, &expression, dot, history, context.allocator)
	if !errs.ok(eval_err) {
		testing.expectf(t, false, "evaluate %q failed: %v", text, eval_err.message)
		errs.destroy(&eval_err)
		return
	}
	testing.expectf(t, got == want, "%q produced [%d, %d), want [%d, %d)", text, got.start, got.end, want.start, want.end)
}

@(test)
test_forward_backward_regex_addresses_and_wraparound :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nneedle one\nαβ🙂 needle two\nlast", 1)
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "/needle/", {}, {5, 11})
	expect_range(t, &doc, "/needle/", {5, 11}, {25, 31})
	expect_range(t, &doc, "/needle/", {36, 40}, {5, 11})
	expect_range(t, &doc, "?needle?", {36, 40}, {25, 31})
	expect_range(t, &doc, "?needle?", {25, 31}, {5, 11})
	expect_range(t, &doc, "?needle?", {5, 11}, {25, 31})
	expect_range(t, &doc, "/αβ🙂/", {}, {16, 24})
	expect_range(t, &doc, "0,/needle/", {}, {0, 11})
	expect_error(t, &doc, "/missing/", {}, .NotFound)
}

@(test)
test_regex_leftmost_longest_newlines_and_anchors :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "aa abab\ncd\n", 1)
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "/a|aa/", {}, {0, 2})
	expect_range(t, &doc, "/ab|abab/", {}, {3, 7})
	expect_range(t, &doc, "/a+/", {}, {0, 2})
	expect_range(t, &doc, "/.*/", {}, {0, 7})
	expect_range(t, &doc, "/[^x]+/", {}, {0, 7})
	expect_range(t, &doc, "/^cd$/", {}, {8, 10})
	expect_range(t, &doc, "/ab\\ncd/", {}, {5, 10})
}

@(test)
test_regex_delimiter_escaping_and_plan9_literals :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a/b a?b d 1 a{2}")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "/a\\/b/", {}, {0, 3})
	expect_range(t, &doc, "?a\\?b?", {7, 7}, {4, 7})
	expect_range(t, &doc, "/\\d/", {}, {8, 9})
	expect_range(t, &doc, "/a{2}/", {}, {12, 16})
}

@(test)
test_empty_regex_reuses_explicit_history :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a1 a2 a1")
	defer txn.doc_destroy(&doc)
	history: address.Regex_History

	expect_range_history(t, &doc, "/a./", {}, &history, {0, 2})
	expect_range_history(t, &doc, "//", {0, 2}, &history, {3, 5})
	expect_range_history(t, &doc, "??", {3, 5}, &history, {0, 2})
	expect_error(t, &doc, "//", {}, .Invalid_Input)
}

@(test)
test_regex_syntax_errors_are_recoverable :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a")
	defer txn.doc_destroy(&doc)

	invalid := []string{"/a", "?a", "/[/", "/(a/", "/a\\", "/a\nb/"}
	for text in invalid {
		expect_error(t, &doc, text, {}, .Invalid_Input)
	}
}

@(test)
test_regex_signs_choose_direction_and_origin :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "x a x b x")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "-/x/", {2, 3}, {0, 1})
	expect_range(t, &doc, "+?x?", {0, 5}, {4, 5})
	expect_range(t, &doc, "-?x?", {4, 5}, {4, 5})
}

@(test)
test_backward_regex_reverses_concatenation_and_can_straddle_dot :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "ab ab")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "?ab|b?", {5, 5}, {3, 5})
	expect_range(t, &doc, "?ab|b?", {4, 4}, {0, 2})
	expect_range(t, &doc, "?ab?", {4, 4}, {0, 2})

	greedy: txn.Doc
	init_doc(t, &greedy, "aa aa")
	defer txn.doc_destroy(&greedy)
	expect_range(t, &greedy, "?a+?", {5, 5}, {3, 5})
	expect_range(t, &greedy, "?a+?", {4, 4}, {3, 4})

	unicode: txn.Doc
	init_doc(t, &unicode, "αβ🙂 x", 1)
	defer txn.doc_destroy(&unicode)
	expect_range(t, &unicode, "?αβ🙂?", {10, 10}, {0, 8})

	anchors: txn.Doc
	init_doc(t, &anchors, "ab\ncd")
	defer txn.doc_destroy(&anchors)
	expect_range(t, &anchors, "?^cd?", {5, 5}, {3, 5})
	expect_range(t, &anchors, "?cd$?", {5, 5}, {3, 5})

	straddling: txn.Doc
	init_doc(t, &straddling, "ab")
	defer txn.doc_destroy(&straddling)
	expect_range(t, &straddling, "/ab/", {1, 1}, {0, 2})
	expect_range(t, &straddling, "?ab?", {1, 1}, {0, 2})
}

@(test)
test_empty_regex_matches_and_line_end_are_zero_width :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "bbb")
	defer txn.doc_destroy(&doc)
	expect_range(t, &doc, "/a*/", {}, {0, 0})
	expect_range(t, &doc, "/a*/", {1, 1}, {1, 1})

	lines: txn.Doc
	init_doc(t, &lines, "a\nb")
	defer txn.doc_destroy(&lines)
	expect_range(t, &lines, "/^/", {}, {0, 0})
	expect_range(t, &lines, "/$/", {}, {1, 1})

	empty: txn.Doc
	init_doc(t, &empty, "")
	defer txn.doc_destroy(&empty)
	expect_range(t, &empty, "/a*/", {}, {0, 0})
	expect_error(t, &empty, "/a+/", {}, .NotFound)
}

expect_error_history :: proc(
	t: ^testing.T,
	doc: ^txn.Doc,
	text: string,
	history: ^address.Regex_History,
	kind: errs.Kind,
) {
	expression, err := address.parse(text, context.allocator)
	if errs.ok(err) {
		_, err = address.evaluate_with_history(&doc.tree, &expression, {}, history, context.allocator)
	}
	testing.expectf(t, err.kind == kind, "%q produced %v, want %v", text, err.kind, kind)
	errs.destroy(&err)
}

@(test)
test_regex_history_updates_on_no_match_but_not_bad_syntax :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "abc")
	defer txn.doc_destroy(&doc)
	history: address.Regex_History

	expect_range_history(t, &doc, "/a/", {}, &history, {0, 1})
	expect_error_history(t, &doc, "/z/", &history, .NotFound)
	expect_error_history(t, &doc, "//", &history, .NotFound)
	expect_range_history(t, &doc, "/b/", {}, &history, {1, 2})
	expect_error_history(t, &doc, "/(/", &history, .Invalid_Input)
	expect_range_history(t, &doc, "//", {}, &history, {1, 2})
}

@(test)
test_regex_escaped_literals_classes_and_group_budget :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a{2} #")
	defer txn.doc_destroy(&doc)
	expect_range(t, &doc, "/a\\{2\\}/", {}, {0, 4})
	expect_range(t, &doc, "/\\#/", {}, {5, 6})

	unicode: txn.Doc
	init_doc(t, &unicode, "αβ🙂\nab", 1)
	defer txn.doc_destroy(&unicode)
	expect_range(t, &unicode, "/[α-🙂]+/", {}, {0, 8})
	expect_range(t, &unicode, "/[\\n]+/", {}, {8, 9})

	nested := make([]u8, 36, context.allocator)
	defer delete(nested, context.allocator)
	nested[0] = '/'
	for index in 1 ..= address.MAX_REGEX_GROUP_DEPTH + 1 {
		nested[index] = '('
	}
	nested[len(nested) - 2] = 'a'
	nested[len(nested) - 1] = '/'
	expect_error(t, &doc, string(nested), {}, .Resource_Limit)
}

@(test)
test_regex_match_crosses_scan_and_rope_chunk_boundaries :: proc(t: ^testing.T) {
	content := make([]u8, address.LINE_SCAN_BYTES + 32, context.allocator)
	defer delete(content, context.allocator)
	for &c in content {
		c = 'a'
	}
	content[address.LINE_SCAN_BYTES - 1] = 'x'
	content[address.LINE_SCAN_BYTES] = 'y'
	doc: txn.Doc
	init_doc(t, &doc, string(content), 64)
	defer txn.doc_destroy(&doc)
	expect_range(t, &doc, "/xy/", {}, {address.LINE_SCAN_BYTES - 1, address.LINE_SCAN_BYTES + 1})
}


@(test)
test_regex_parser_records_direction_origin_and_empty_pattern :: proc(t: ^testing.T) {
	expression, err := address.parse("+?a\\?b?", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, expression.operation_count == 1)
	operation := expression.operations[0]
	testing.expect(t, operation.kind == .Regex && operation.direction == .Backward && operation.origin == .Forward)
	testing.expect(t, string(expression.pattern_bytes[:expression.pattern_bytes_used]) == "a\\?b")

	expression, err = address.parse("-?a?", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	operation = expression.operations[0]
	testing.expect(t, operation.direction == .Forward && operation.origin == .Backward)

	expression, err = address.parse("/a///", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, expression.operation_count == 2)
	testing.expect(t, expression.operations[0].pattern_length == 1)
	testing.expect(t, expression.operations[1].pattern_length == 0)
}

@(test)
test_regex_history_preserves_escaped_backward_delimiter :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a?b a?b")
	defer txn.doc_destroy(&doc)
	history: address.Regex_History
	expect_range_history(t, &doc, "?a\\?b?", {7, 7}, &history, {4, 7})
	expect_range_history(t, &doc, "//", {4, 7}, &history, {0, 3})
}

@(test)
test_backward_empty_match_and_repeated_postfix_operators :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "aaabbb")
	defer txn.doc_destroy(&doc)
	expect_range(t, &doc, "?b*?", {4, 4}, {3, 4})
	expect_range(t, &doc, "?a*?", {3, 3}, {0, 3})
	expect_range(t, &doc, "/a**/", {}, {0, 3})
}


@(test)
test_regex_find_matches_captures_and_range_limit :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "aa xa\naa\nya", 1)
	defer txn.doc_destroy(&doc)
	history: address.Regex_History
	matches, err := address.regex_find_matches(&doc.tree, "(a|aa)(z)?", {0, 2}, &history, 2, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer delete(matches, context.allocator)
	testing.expect(t, len(matches) == 1)
	testing.expect(t, matches[0].range == rope.Byte_Range{0, 2})
	testing.expect(t, matches[0].groups[1] == rope.Byte_Range{0, 2})
	testing.expect(t, matches[0].groups[2].start == -1 && matches[0].groups[2].end == -1)

	limited, find_err := address.regex_find_matches(&doc.tree, "a", {6, 8}, &history, 4, context.allocator)
	testing.expect(t, errs.ok(find_err))
	errs.destroy(&find_err)
	defer delete(limited, context.allocator)
	testing.expect(t, len(limited) == 2)
	testing.expect(t, limited[0].range == rope.Byte_Range{6, 7})
	testing.expect(t, limited[1].range == rope.Byte_Range{7, 8})

	reused, history_err := address.regex_find_matches(&doc.tree, "", {0, 2}, &history, 1, context.allocator)
	testing.expect(t, errs.ok(history_err))
	errs.destroy(&history_err)
	defer delete(reused, context.allocator)
	testing.expect(t, len(reused) == 1 && reused[0].range == rope.Byte_Range{0, 1})
}

@(test)
test_regex_find_matches_empty_match_progress :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "bb aa", 1)
	defer txn.doc_destroy(&doc)
	matches, err := address.regex_find_matches(&doc.tree, "a*", {0, 2}, nil, 4, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer delete(matches, context.allocator)
	testing.expect(t, len(matches) == 3)
	for match, index in matches {
		testing.expect(t, match.range == rope.Byte_Range{index, index})
	}

	nonempty, find_err := address.regex_find_matches(&doc.tree, "a*", {3, 5}, nil, 4, context.allocator)
	testing.expect(t, errs.ok(find_err))
	errs.destroy(&find_err)
	defer delete(nonempty, context.allocator)
	testing.expect(t, len(nonempty) == 1)
	testing.expect(t, nonempty[0].range == rope.Byte_Range{3, 5})
}


@(test)
test_regex_search_honors_cancellation :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_err := txn.doc_init_from_bytes(&doc, transmute([]byte)string("a a a"), {}, context.allocator)
	testing.expect(t, errs.ok(init_err))
	errs.destroy(&init_err)
	defer txn.doc_destroy(&doc)

	cancelled := false
	sync.atomic_store(&cancelled, true)
	matches, find_err := address.regex_find_matches(&doc.tree, "a", {0, 5}, nil, 4, context.allocator, &cancelled)
	testing.expect(t, find_err.kind == .Cancelled)
	errs.destroy(&find_err)
	testing.expect(t, len(matches) == 0)

	expression, parse_err := address.parse("/a/", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	_, eval_err := address.evaluate_with_history(&doc.tree, &expression, {}, nil, context.allocator, &cancelled)
	testing.expect(t, eval_err.kind == .Cancelled)
	errs.destroy(&eval_err)
}
