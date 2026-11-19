package edit_test

import "core:bytes"
import "core:testing"

import address "hammer:core/address"
import edit "hammer:core/edit"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

init_doc :: proc(t: ^testing.T, doc: ^txn.Doc, text: string) {
	err := txn.doc_init_from_bytes(doc, transmute([]byte)text, {chunk_size = 1}, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
}

expect_content :: proc(t: ^testing.T, doc: ^txn.Doc, want: string) {
	got, err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer delete(got, context.allocator)
	testing.expectf(t, bytes.equal(got, transmute([]byte)want), "content %q, want %q", got, want)
}

expect_selection :: proc(t: ^testing.T, selection: txn.Selection, start, end: int) {
	testing.expectf(
		t,
		selection.anchor == start && selection.active == end,
		"selection [%d, %d), want [%d, %d)",
		selection.anchor,
		selection.active,
		start,
		end,
	)
}

run :: proc(t: ^testing.T, doc: ^txn.Doc, selection: ^txn.Selection, text: string, history: ^address.Regex_History = nil) -> errs.Error {
	program, err := edit.parse(text, context.allocator)
	if !errs.ok(err) {
		return err
	}
	defer edit.program_destroy(&program, context.allocator)
	return edit.execute(doc, selection, &program, history, 41, context.allocator)
}

expect_run_error :: proc(t: ^testing.T, doc: ^txn.Doc, selection: ^txn.Selection, text: string, kind: errs.Kind) {
	err := run(t, doc, selection, text)
	testing.expectf(t, err.kind == kind, "%q returned %v, want %v", text, err.kind, kind)
	errs.destroy(&err)
}

@(test)
test_insert_append_change_and_delete :: proc(t: ^testing.T) {
	cases := []struct {
		command:   string,
		selection: txn.Selection,
		want:      string,
		dot_start:  int,
		dot_end:    int,
	}{
		{"i/before /", {anchor = 4, active = 4}, "one before two\n", 4, 11},
		{"a/ after/", {anchor = 0, active = 3}, "one after two\n", 3, 9},
		{"c/three/", {anchor = 0, active = 3}, "three two\n", 0, 5},
		{"1c/first\\nsecond\\n/", {}, "first\nsecond\n", 0, 13},
		{"1d", {}, "", 0, 0},
	}
	for test in cases {
		doc: txn.Doc
		init_doc(t, &doc, "one two\n")
		defer txn.doc_destroy(&doc)
		selection := test.selection
		err := run(t, &doc, &selection, test.command)
		testing.expectf(t, errs.ok(err), "%q failed: %v", test.command, err)
		errs.destroy(&err)
		expect_content(t, &doc, test.want)
		expect_selection(t, selection, test.dot_start, test.dot_end)
		testing.expect(t, txn.doc_log_len(&doc) == 1)
		testing.expect(t, doc.log[0].source == .Edit)
		testing.expect(t, doc.log[0].grouping_key == 41)
	}
}

@(test)
test_multiline_and_unicode_text :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "αβ🙂\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := run(t, &doc, &selection, "a§λ🙂§")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "λ🙂αβ🙂\n")
	expect_selection(t, selection, 0, 6)

	err = run(t, &doc, &selection, "c\nfirst\n.\n")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "first\nαβ🙂\n")
	expect_selection(t, selection, 0, 6)

	err = run(t, &doc, &selection, "c\nfirst\nsecond\n.\n")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "first\nsecond\nαβ🙂\n")
}

@(test)
test_text_escapes_and_delimiters :: proc(t: ^testing.T) {
	program, err := edit.parse("a/x\\ny\\t\\/z\\\\\\q/", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer edit.program_destroy(&program, context.allocator)
	testing.expect(t, len(program.commands) == 1)
	got := edit.command_text(&program, program.commands[0])
	testing.expectf(t, bytes.equal(got, transmute([]byte)string("x\ny\\t/z\\\\q")), "decoded text %q", got)

	delimited := []string{"a/foo", "a/foo\n", "a§λ§"}
	for text in delimited {
		parsed, parse_err := edit.parse(text, context.allocator)
		testing.expectf(t, errs.ok(parse_err), "%q failed to parse", text)
		errs.destroy(&parse_err)
		edit.program_destroy(&parsed, context.allocator)
	}
}

@(test)
test_sequential_commands_are_one_undo_group :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\ntwo\nthree\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := run(t, &doc, &selection, "1i/before\\n/\n2a/after\\n/\n3d\n")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "before\none\ntwo\nthree\n")
	expect_selection(t, selection, 11, 11)
	testing.expect(t, txn.doc_log_len(&doc) == 3)
	for entry in doc.log {
		testing.expect(t, entry.grouping_key == 41)
	}

	_, undo_err := txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "one\ntwo\nthree\n")
	_, redo_err := txn.doc_redo(&doc, context.allocator)
	testing.expect(t, errs.ok(redo_err))
	errs.destroy(&redo_err)
	expect_content(t, &doc, "before\none\ntwo\nthree\n")

	err = run(t, &doc, &selection, "0a/X/")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "Xbefore\none\ntwo\nthree\n")
	testing.expect(t, doc.log[len(doc.log) - 1].grouping_key != 41)
	_, undo_err = txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "before\none\ntwo\nthree\n")
}

@(test)
test_bare_addresses_and_regex_history :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "alpha\nβeta\nalpha\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	err := run(t, &doc, &selection, "2\n", &history)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_selection(t, selection, 6, 12)
	testing.expect(t, txn.doc_log_len(&doc) == 0)

	err = run(t, &doc, &selection, "/βeta/\n//d\n", &history)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "alpha\n\nalpha\n")
	expect_selection(t, selection, 6, 6)
	testing.expect(t, history.pattern_length > 0)
}

@(test)
test_move_and_copy :: proc(t: ^testing.T) {
	cases := []struct {
		command:   string,
		want:      string,
		dot_start: int,
		dot_end:    int,
	}{
		{"#0,#3m#9", "DEFghiabc\n", 6, 9},
		{"#6,#9m#0", "ghiabcDEF\n", 0, 3},
		{"#0,#3t#9", "abcDEFghiabc\n", 9, 12},
		{"#0,#3t#1", "aabcbcDEFghi\n", 1, 4},
	}
	for test in cases {
		doc: txn.Doc
		init_doc(t, &doc, "abcDEFghi\n")
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		err := run(t, &doc, &selection, test.command)
		testing.expectf(t, errs.ok(err), "%q failed: %v", test.command, err)
		errs.destroy(&err)
		expect_content(t, &doc, test.want)
		expect_selection(t, selection, test.dot_start, test.dot_end)
	}
}

@(test)
test_move_overlap_and_unicode_boundary_errors_preserve_text :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "abcDEFghi\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	expect_run_error(t, &doc, &selection, "#0,#3m#1", .Invalid_Input)
	expect_content(t, &doc, "abcDEFghi\n")
	testing.expect(t, txn.doc_log_len(&doc) == 0)

	unicode_doc: txn.Doc
	init_doc(t, &unicode_doc, "αβ🙂\n")
	defer txn.doc_destroy(&unicode_doc)
	invalid_selection := txn.Selection{anchor = 1, active = 1}
	expect_run_error(t, &unicode_doc, &invalid_selection, "d", .Invalid_Input)
	expect_content(t, &unicode_doc, "αβ🙂\n")
}

@(test)
test_parse_errors_are_atomic_and_unsupported_commands_do_not_run :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\ntwo\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	invalid := []string{"a", "a\nunterminated", "m", "1,2m0,1", "1d x", "1,,2d"}
	for text in invalid {
		expect_run_error(t, &doc, &selection, text, .Invalid_Input)
	}
	unsupported := []string{"s/x/y/", "x/a/d", "g/a/d"}
	for text in unsupported {
		expect_run_error(t, &doc, &selection, text, .Unsupported)
	}
	expect_run_error(t, &doc, &selection, "0a/new/\n1d x", .Invalid_Input)
	expect_content(t, &doc, "one\ntwo\n")
	testing.expect(t, txn.doc_log_len(&doc) == 0)
}

@(test)
test_runtime_error_after_mutation_remains_one_undo_group :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	expect_run_error(t, &doc, &selection, "0a/new/\n99d", .NotFound)
	expect_content(t, &doc, "newone\n")
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	_, undo_err := txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "one\n")
}

@(test)
test_empty_and_zero_length_commands_update_dot_without_history :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := run(t, &doc, &selection, "")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	err = run(t, &doc, &selection, "#2d")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "one\n")
	expect_selection(t, selection, 2, 2)
	testing.expect(t, txn.doc_log_len(&doc) == 0)
}

@(test)
test_command_budgets :: proc(t: ^testing.T) {
	oversized := make([]byte, edit.MAX_EDIT_BYTES + 1, context.allocator)
	defer delete(oversized, context.allocator)
	program, err := edit.parse(string(oversized), context.allocator)
	testing.expect(t, err.kind == .Resource_Limit)
	errs.destroy(&err)
	edit.program_destroy(&program, context.allocator)

	commands := make([]byte, 2*(edit.MAX_COMMANDS+1), context.allocator)
	defer delete(commands, context.allocator)
	for index := 0; index < len(commands); index += 2 {
		commands[index] = 'd'
		commands[index + 1] = '\n'
	}
	program, err = edit.parse(string(commands), context.allocator)
	testing.expect(t, err.kind == .Resource_Limit)
	errs.destroy(&err)
	edit.program_destroy(&program, context.allocator)
}


@(test)
test_open_ranges_and_long_text_after_address_prefix :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\ntwo\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := run(t, &doc, &selection, "1,d")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "")

	long_doc: txn.Doc
	init_doc(t, &long_doc, "old\n")
	defer txn.doc_destroy(&long_doc)
	payload := make([]byte, address.MAX_ADDRESS_BYTES+1024, context.allocator)
	defer delete(payload, context.allocator)
	for index in 0 ..< len(payload) {
		payload[index] = 'x'
	}
	command := make([dynamic]u8, context.allocator)
	defer delete(command)
	append(&command, ..transmute([]byte)string("1c/"))
	append(&command, ..payload)
	append(&command, '/')
	err = run(t, &long_doc, &selection, string(command[:]))
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	got, read_err := rope.tree_read_all(&long_doc.tree, {0, rope.tree_byte_count(&long_doc.tree)}, context.allocator)
	testing.expect(t, errs.ok(read_err))
	errs.destroy(&read_err)
	defer delete(got, context.allocator)
	testing.expect(t, bytes.equal(got, payload))
}
