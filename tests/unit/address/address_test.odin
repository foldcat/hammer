package address_test

import "core:testing"

import address "hammer:core/address"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

init_doc :: proc(t: ^testing.T, doc: ^txn.Doc, text: string, chunk_size := 3) {
	err := txn.doc_init_from_bytes(doc, transmute([]byte)text, {chunk_size = chunk_size}, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
}

expect_range :: proc(t: ^testing.T, doc: ^txn.Doc, text: string, dot: rope.Byte_Range, want: rope.Byte_Range) {
	expression, parse_err := address.parse(text, context.allocator)
	if !errs.ok(parse_err) {
		testing.expectf(t, false, "parse %q failed: %v", text, parse_err.message)
		errs.destroy(&parse_err)
		return
	}
	got, eval_err := address.evaluate(&doc.tree, &expression, dot, context.allocator)
	if !errs.ok(eval_err) {
		testing.expectf(t, false, "evaluate %q failed: %v", text, eval_err.message)
		errs.destroy(&eval_err)
		return
	}
	testing.expectf(t, got == want, "%q produced [%d, %d), want [%d, %d)", text, got.start, got.end, want.start, want.end)
}

expect_error :: proc(t: ^testing.T, doc: ^txn.Doc, text: string, dot: rope.Byte_Range, kind: errs.Kind) {
	expression, err := address.parse(text, context.allocator)
	if errs.ok(err) {
		_, err = address.evaluate(&doc.tree, &expression, dot, context.allocator)
	}
	testing.expectf(t, err.kind == kind, "%q produced %v, want %v", text, err.kind, kind)
	errs.destroy(&err)
}

@(test)
test_absolute_lines_dot_and_end :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast")
	defer txn.doc_destroy(&doc)

	cases := []struct {
		text: string,
		want: rope.Byte_Range,
	}{
		{"0", {0, 0}},
		{"1", {0, 5}},
		{"2", {5, 14}},
		{"3", {14, 20}},
		{"4", {20, 21}},
		{"5", {21, 25}},
		{"$", {25, 25}},
		{".", {5, 14}},
		{" 2 ", {5, 14}},
	}
	for test in cases {
		expect_range(t, &doc, test.text, {5, 14}, test.want)
	}
	expect_error(t, &doc, "6", {}, .NotFound)
}

@(test)
test_character_addresses_count_unicode_scalars :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast", 1)
	defer txn.doc_destroy(&doc)

	cases := []struct {
		text: string,
		want: rope.Byte_Range,
	}{
		{"#0", {0, 0}},
		{"#4", {4, 4}},
		{"#5", {5, 5}},
		{"#6", {7, 7}},
		{"#7", {9, 9}},
		{"#8", {13, 13}},
		{"#9", {14, 14}},
		{"#20", {25, 25}},
	}
	for test in cases {
		expect_range(t, &doc, test.text, {}, test.want)
	}
	expect_error(t, &doc, "#21", {}, .NotFound)
}

@(test)
test_relative_line_addresses :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "+", {0, 5}, {5, 14})
	expect_range(t, &doc, "-", {14, 20}, {5, 14})
	expect_range(t, &doc, "+2", {}, {5, 14})
	expect_range(t, &doc, "-2", {20, 21}, {5, 14})
	expect_range(t, &doc, "1+2", {}, {14, 20})
	expect_range(t, &doc, "+-", {5, 14}, {5, 14})
	expect_range(t, &doc, "+0", {7, 7}, {7, 14})
	expect_range(t, &doc, "-0", {7, 7}, {5, 7})
	expect_range(t, &doc, "-0", {5, 5}, {0, 5})
	expect_range(t, &doc, "1-", {}, {0, 0})
	expect_error(t, &doc, "+", {21, 25}, .NotFound)
	expect_error(t, &doc, "-2", {0, 5}, .NotFound)
}

@(test)
test_relative_character_addresses_and_implicit_forward_motion :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "+#4", {0, 5}, {14, 14})
	expect_range(t, &doc, "-#2", {14, 20}, {9, 9})
	expect_range(t, &doc, "1+#2", {}, {9, 9})
	expect_range(t, &doc, "1#2", {}, {9, 9})
	expect_range(t, &doc, "2 + #1", {}, {15, 15})
	expect_error(t, &doc, "-#1", {}, .NotFound)
	expect_error(t, &doc, "+#1", {25, 25}, .NotFound)
	expect_error(t, &doc, "+#1", {6, 6}, .Invalid_Input)
}

@(test)
test_comma_ranges_and_defaults :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, ",", {}, {0, 25})
	expect_range(t, &doc, "2,4", {}, {5, 21})
	expect_range(t, &doc, "2,", {}, {5, 25})
	expect_range(t, &doc, ",2", {}, {0, 14})
	expect_range(t, &doc, "2,1", {}, {5, 5})
	expect_range(t, &doc, "1,2,3", {}, {0, 20})
	expect_error(t, &doc, "3,1", {}, .Invalid_Input)
}

@(test)
test_semicolon_sets_dot_for_right_hand_side :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "zero\nαβ🙂\nthird\n\nlast")
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "2;+#1", {}, {5, 15})
	expect_error(t, &doc, "2,+#1", {}, .Invalid_Input)
	expect_range(t, &doc, "2;.,$", {7, 9}, {5, 25})
}

@(test)
test_empty_trailing_newline_and_crlf_documents :: proc(t: ^testing.T) {
	empty: txn.Doc
	init_doc(t, &empty, "")
	defer txn.doc_destroy(&empty)
	expect_range(t, &empty, "1", {}, {0, 0})
	expect_range(t, &empty, "+", {}, {0, 0})
	expect_range(t, &empty, "-", {}, {0, 0})
	expect_error(t, &empty, "2", {}, .NotFound)
	expect_error(t, &empty, "-2", {}, .NotFound)

	trailing: txn.Doc
	init_doc(t, &trailing, "a\nb\n", 1)
	defer txn.doc_destroy(&trailing)
	expect_range(t, &trailing, "3", {}, {4, 4})
	expect_range(t, &trailing, "+", {2, 4}, {4, 4})
	expect_error(t, &trailing, "4", {}, .NotFound)

	crlf: txn.Doc
	init_doc(t, &crlf, "a\rb\r\nc", 1)
	defer txn.doc_destroy(&crlf)
	expect_range(t, &crlf, "1", {}, {0, 5})
	expect_range(t, &crlf, "2", {}, {5, 6})
	expect_range(t, &crlf, "#2", {}, {2, 2})
}

@(test)
test_syntax_invalid_constructs_and_budgets :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a\nb\n")
	defer txn.doc_destroy(&doc)

	invalid := []string{"", " \t", "#", "1,,2", "1,,", "1.", ".$", "1 x"}
	for text in invalid {
		expect_error(t, &doc, text, {}, .Invalid_Input)
	}
	expect_range(t, &doc, "/a/", {}, {0, 1})
	expect_range(t, &doc, "?b?", {4, 4}, {2, 3})
	expect_range(t, &doc, "1,/a/", {}, {0, 1})
	expect_error(t, &doc, "999999999999999999999999999999", {}, .Resource_Limit)

	oversized := make([]byte, address.MAX_ADDRESS_BYTES + 1, context.allocator)
	defer delete(oversized, context.allocator)
	expect_error(t, &doc, string(oversized), {}, .Resource_Limit)

	operations := make([]byte, address.MAX_OPERATIONS + 1, context.allocator)
	defer delete(operations, context.allocator)
	for index in 0 ..< len(operations) {
		operations[index] = '+'
	}
	expect_error(t, &doc, string(operations), {}, .Resource_Limit)

	ranges := make([]byte, 2 * (address.MAX_RANGE_DEPTH + 2) + 1, context.allocator)
	defer delete(ranges, context.allocator)
	for index in 0 ..< address.MAX_RANGE_DEPTH + 2 {
		ranges[2 * index] = '1'
		ranges[2 * index + 1] = ','
	}
	ranges[len(ranges) - 1] = '1'
	expect_error(t, &doc, string(ranges), {}, .Resource_Limit)
}

@(test)
test_parser_builds_typed_operation_and_range_nodes :: proc(t: ^testing.T) {
	expression, err := address.parse("1+#2", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, expression.operation_count == 2 && expression.node_count == 1)
	first := expression.operations[0]
	second := expression.operations[1]
	testing.expect(t, first.kind == .Line && first.direction == .Absolute && first.count == 1)
	testing.expect(t, second.kind == .Character && second.direction == .Forward && second.count == 2)

	expression, err = address.parse("2;.,$", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	root := expression.nodes[expression.root]
	testing.expect(t, root.kind == .Range && root.separator == .Semicolon)
	testing.expect(t, root.left >= 0 && root.right >= 0)
}


@(test)
test_line_scans_cross_fixed_buffer_and_rope_chunks :: proc(t: ^testing.T) {
	content := make([]byte, address.LINE_SCAN_BYTES + 1234, context.allocator)
	defer delete(content, context.allocator)
	for index in 0 ..< len(content) {
		content[index] = 'x'
	}
	newline := address.LINE_SCAN_BYTES + 17
	content[newline] = '\n'
	doc: txn.Doc
	init_doc(t, &doc, string(content), 64)
	defer txn.doc_destroy(&doc)

	expect_range(t, &doc, "2", {}, {newline + 1, len(content)})
	expect_range(t, &doc, "+", {0, newline + 1}, {newline + 1, len(content)})
	expect_range(t, &doc, "-", {newline + 1, len(content)}, {0, newline + 1})
}

@(test)
test_evaluator_rejects_invalid_inputs :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a")
	defer txn.doc_destroy(&doc)
	expect_error(t, &doc, "1", {0, 2}, .Invalid_Input)

	expression: address.Expression
	_, err := address.evaluate(&doc.tree, &expression, {}, context.allocator)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)

	valid, parse_err := address.parse("1", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	_, err = address.evaluate(nil, &valid, {}, context.allocator)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	_, err = address.evaluate(&doc.tree, nil, {}, context.allocator)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
}
