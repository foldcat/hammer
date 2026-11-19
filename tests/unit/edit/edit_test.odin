package edit_test

import "core:bytes"
import "core:testing"
import "core:time"

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

expect_run_error :: proc(t: ^testing.T, doc: ^txn.Doc, selection: ^txn.Selection, text: string, kind: errs.Kind, history: ^address.Regex_History = nil) {
	err := run(t, doc, selection, text, history)
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
	unsupported := []string{"x/a/d", "g/a/d"}
	for text in unsupported {
		expect_run_error(t, &doc, &selection, text, .Unsupported)
	}
	expect_run_error(t, &doc, &selection, ",s/missing/y/", .NotFound)
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


@(test)
test_substitution_occurrences_global_and_address_range :: proc(t: ^testing.T) {
	cases := []struct {
		initial: string,
		command: string,
		want:    string,
	}{
		{"a a a", ",s/a/X/", "X a a"},
		{"a a a", ",s2/a/X/", "a X a"},
		{"a a a", ",s2/a/X/g", "a X X"},
		{"a a a", ",s/a/X/g", "X X X"},
		{"a\na\na\n", "2s/a/X/", "a\nX\na\n"},
		{"a\na\na\n", "2,$s/a/X/g", "a\nX\nX\n"},
	}
	for test in cases {
		doc: txn.Doc
		init_doc(t, &doc, test.initial)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		err := run(t, &doc, &selection, test.command)
		testing.expectf(t, errs.ok(err), "%q failed: %v", test.command, err)
		errs.destroy(&err)
		expect_content(t, &doc, test.want)
		testing.expect(t, txn.doc_log_len(&doc) == 1)
		check_err := txn.doc_check(&doc, context.allocator)
		testing.expect(t, errs.ok(check_err))
		errs.destroy(&check_err)
	}
}

@(test)
test_substitution_captures_and_replacement_escapes :: proc(t: ^testing.T) {
	cases := []struct {
		initial: string,
		command: string,
		want:    string,
	}{
		{"ab ab", ",s/(a)(b)/\\2\\1/", "ba ab"},
		{"ab ab", ",s/(a)(b)/\\2\\1/g", "ba ba"},
		{"ab ab", ",s/(a)(b)/[&]-\\1-\\2/", "[ab]-a-b ab"},
		{"a", ",s/(a)(z)?/<\\2>/", "<>"},
		{"a", ",s/a/\\&/", "&"},
		{"a", ",s/a/\\\\/", "\\"},
		{"a", ",s/a/x\\ny/", "x\ny"},
		{"a/b a/b", ",s/a\\/b/c\\/d/g", "c/d c/d"},
		{"aa", ",s/a|aa/X/", "X"},
	}
	for test in cases {
		doc: txn.Doc
		init_doc(t, &doc, test.initial)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		err := run(t, &doc, &selection, test.command)
		testing.expectf(t, errs.ok(err), "%q failed: %v", test.command, err)
		errs.destroy(&err)
		expect_content(t, &doc, test.want)
	}
}

@(test)
test_substitution_empty_matches_and_anchors :: proc(t: ^testing.T) {
	cases := []struct {
		initial: string,
		command: string,
		want:    string,
	}{
		{"bb", ",s/a*/X/g", "XbXbX"},
		{"aa", ",s/a*/X/g", "X"},
		{"ββ", ",s/α*/X/g", "XβXβX"},
		{"a\nb\n", "2s/^/X/", "a\nXb\n"},
		{"a\nb\n", "2s/$/X/", "a\nbX\n"},
	}
	for test in cases {
		doc: txn.Doc
		init_doc(t, &doc, test.initial)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{}
		err := run(t, &doc, &selection, test.command)
		testing.expectf(t, errs.ok(err), "%q failed: %v", test.command, err)
		errs.destroy(&err)
		expect_content(t, &doc, test.want)
	}
}

@(test)
test_substitution_history_and_invalid_pattern :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a a")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	err := run(t, &doc, &selection, ",s/a/x/", &history)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "x a")
	err = run(t, &doc, &selection, ",s//y/", &history)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "x y")
	expect_run_error(t, &doc, &selection, ",s/(/z/", .Invalid_Input, &history)
	expect_run_error(t, &doc, &selection, ",s//q/", .NotFound, &history)
	testing.expect(t, string(history.pattern_bytes[:history.pattern_length]) == "a")
	expect_run_error(t, &doc, &selection, ",s/z/n/", .NotFound, &history)
	expect_run_error(t, &doc, &selection, ",s//q/", .NotFound, &history)
	expect_content(t, &doc, "x y")
	testing.expect(t, string(history.pattern_bytes[:history.pattern_length]) == "z")
}

@(test)
test_global_substitution_is_one_undo_transaction :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a a a")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	err := run(t, &doc, &selection, ",s/a/X/g")
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_content(t, &doc, "X X X")
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	_, undo_err := txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "a a a")
	_, redo_err := txn.doc_redo(&doc, context.allocator)
	testing.expect(t, errs.ok(redo_err))
	errs.destroy(&redo_err)
	expect_content(t, &doc, "X X X")
}

@(test)
test_substitution_parser_and_result_budget :: proc(t: ^testing.T) {
	program, parse_err := edit.parse("s12/a/b/g", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	defer edit.program_destroy(&program, context.allocator)
	testing.expect(t, len(program.commands) == 1)
	command := program.commands[0]
	testing.expect(t, command.kind == .Substitute && command.count == 12 && command.global)
	testing.expect(t, edit.command_pattern(&program, command) == "a")
	testing.expect(t, bytes.equal(edit.command_text(&program, command), transmute([]byte)string("b")))

	doc: txn.Doc
	init_doc(t, &doc, "a")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	expect_run_error(t, &doc, &selection, ",s4097/a/X/g", .Resource_Limit)
	expect_run_error(t, &doc, &selection, "s", .Invalid_Input)

	many := make([]byte, address.MAX_REGEX_MATCHES + 1, context.allocator)
	defer delete(many, context.allocator)
	for &c in many {
		c = 'a'
	}
	many_doc: txn.Doc
	init_doc(t, &many_doc, string(many))
	defer txn.doc_destroy(&many_doc)
	expect_run_error(t, &many_doc, &selection, ",s/a/X/g", .Resource_Limit)
	testing.expect(t, rope.tree_byte_count(&many_doc.tree) == len(many))
	testing.expect(t, txn.doc_log_len(&many_doc) == 0)
}


wait_for_edit_result :: proc(t: ^testing.T, runner: ^edit.Runner) -> ^edit.Result {
	for _ in 0 ..< 2000 {
		if result, ok := edit.runner_poll(runner); ok {
			return result
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "timed out waiting for asynchronous Edit")
	return nil
}

@(test)
test_async_snapshot_result_applies_as_one_undo_group :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a a a")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	program, parse_err := edit.parse(",s/(a)/[\\1]/g", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	defer edit.program_destroy(&program, context.allocator)

	runner: edit.Runner
	start_err := edit.runner_start(&runner, &doc, selection, &program, history, 7, 3, 0, 99, 41, context.allocator)
	testing.expect(t, errs.ok(start_err))
	errs.destroy(&start_err)
	if !edit.runner_active(&runner) {
		return
	}
	defer edit.runner_destroy(&runner)

	busy_err := edit.runner_start(&runner, &doc, selection, &program, history, 7, 3, 0, 100, 42, context.allocator)
	testing.expect(t, busy_err.kind == .Resource_Limit)
	errs.destroy(&busy_err)

	result := wait_for_edit_result(t, &runner)
	if result == nil {
		return
	}
	testing.expect(t, result.target_id == 7 && result.target_generation == 3)
	testing.expect(t, result.source_revision == 0 && result.request_id == 99)
	testing.expect(t, errs.ok(result.err))

	stale_err := edit.apply_result(&doc, &selection, &history, result, 7, 3, 100, context.allocator)
	testing.expect(t, stale_err.kind == .Conflict)
	errs.destroy(&stale_err)
	expect_content(t, &doc, "a a a")

	apply_err := edit.apply_result(&doc, &selection, &history, result, 7, 3, 99, context.allocator)
	testing.expect(t, errs.ok(apply_err))
	errs.destroy(&apply_err)
	expect_content(t, &doc, "[a] [a] [a]")
	expect_selection(t, selection, 0, 5)
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	testing.expect(t, doc.log[0].grouping_key == 41)
	_, undo_err := txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "a a a")
}

@(test)
test_async_stale_revision_applies_nothing :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "a a")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	program, parse_err := edit.parse(",s/a/X/g", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	defer edit.program_destroy(&program, context.allocator)

	runner: edit.Runner
	start_err := edit.runner_start(&runner, &doc, selection, &program, history, 7, 3, 0, 99, 41, context.allocator)
	testing.expect(t, errs.ok(start_err))
	errs.destroy(&start_err)
	if !edit.runner_active(&runner) {
		return
	}
	defer edit.runner_destroy(&runner)

	operation := txn.Operation(txn.Insert{pos = 0, data = transmute([]byte)string("!")})
	transaction := txn.Transaction{
		source = .Typing,
		base_revision = 0,
		ops = []txn.Operation{operation},
		after_selection = {anchor = 1, active = 1, affinity = .Right},
	}
	edit_err := txn.doc_apply(&doc, &transaction, context.allocator)
	testing.expect(t, errs.ok(edit_err))
	errs.destroy(&edit_err)
	selection = transaction.after_selection

	result := wait_for_edit_result(t, &runner)
	if result == nil {
		return
	}
	apply_err := edit.apply_result(&doc, &selection, &history, result, 7, 3, 99, context.allocator)
	testing.expect(t, apply_err.kind == .Conflict)
	errs.destroy(&apply_err)
	expect_content(t, &doc, "!a a")
	expect_selection(t, selection, 1, 1)
	testing.expect(t, txn.doc_log_len(&doc) == 1)
}

@(test)
test_async_cancellation_applies_nothing :: proc(t: ^testing.T) {
	content := make([]byte, 64 * 1024, context.allocator)
	defer delete(content, context.allocator)
	for &c in content {
		c = 'a'
	}
	doc: txn.Doc
	init_doc(t, &doc, string(content))
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	program, parse_err := edit.parse(",s/(a|aa)*b/X/g", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	defer edit.program_destroy(&program, context.allocator)

	runner: edit.Runner
	start_err := edit.runner_start(&runner, &doc, selection, &program, history, 7, 3, 0, 99, 41, context.allocator)
	testing.expect(t, errs.ok(start_err))
	errs.destroy(&start_err)
	if !edit.runner_active(&runner) {
		return
	}
	defer edit.runner_destroy(&runner)
	edit.runner_cancel(&runner)

	result := wait_for_edit_result(t, &runner)
	if result == nil {
		return
	}
	testing.expect(t, result.err.kind == .Cancelled)
	testing.expect(t, len(result.batches) == 0)
	apply_err := edit.apply_result(&doc, &selection, &history, result, 7, 3, 99, context.allocator)
	testing.expect(t, apply_err.kind == .Cancelled)
	errs.destroy(&apply_err)
	testing.expect(t, rope.tree_byte_count(&doc.tree) == len(content))
	testing.expect(t, txn.doc_log_len(&doc) == 0)
	expect_selection(t, selection, 0, 0)
}

@(test)
test_async_runtime_error_replays_successful_prefix :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_doc(t, &doc, "one\n")
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	history: address.Regex_History
	program, parse_err := edit.parse("0a/new/\n99d", context.allocator)
	testing.expect(t, errs.ok(parse_err))
	errs.destroy(&parse_err)
	defer edit.program_destroy(&program, context.allocator)

	runner: edit.Runner
	start_err := edit.runner_start(&runner, &doc, selection, &program, history, 7, 3, 0, 99, 41, context.allocator)
	testing.expect(t, errs.ok(start_err))
	errs.destroy(&start_err)
	if !edit.runner_active(&runner) {
		return
	}
	defer edit.runner_destroy(&runner)
	result := wait_for_edit_result(t, &runner)
	if result == nil {
		return
	}
	testing.expect(t, result.err.kind == .NotFound)
	apply_err := edit.apply_result(&doc, &selection, &history, result, 7, 3, 99, context.allocator)
	testing.expect(t, apply_err.kind == .NotFound)
	errs.destroy(&apply_err)
	expect_content(t, &doc, "newone\n")
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	_, undo_err := txn.doc_undo(&doc, context.allocator)
	testing.expect(t, errs.ok(undo_err))
	errs.destroy(&undo_err)
	expect_content(t, &doc, "one\n")
}

@(test)
test_multi_buffer_results_apply_after_shared_validation :: proc(t: ^testing.T) {
	first_doc, second_doc: txn.Doc
	init_doc(t, &first_doc, "first")
	init_doc(t, &second_doc, "second")
	defer txn.doc_destroy(&first_doc)
	defer txn.doc_destroy(&second_doc)
	first_selection, second_selection: txn.Selection
	first_history, second_history: address.Regex_History

	first_result := edit.Result{
		target_id = 1,
		target_generation = 10,
		source_revision = 0,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 0, data = transmute([]byte)string("A")}},
			after_selection = {anchor = 0, active = 1, affinity = .Right},
		}},
		selection = {anchor = 0, active = 1, affinity = .Right},
	}
	second_result := edit.Result{
		target_id = 2,
		target_generation = 20,
		source_revision = 0,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 6, data = transmute([]byte)string("B")}},
			after_selection = {anchor = 6, active = 7, affinity = .Right},
		}},
		selection = {anchor = 6, active = 7, affinity = .Right},
	}
	targets := []edit.Result_Target{
		{
			doc = &first_doc,
			selection = &first_selection,
			history = &first_history,
			result = &first_result,
			target_id = 1,
			target_generation = 10,
			request_id = 100,
		},
		{
			doc = &second_doc,
			selection = &second_selection,
			history = &second_history,
			result = &second_result,
			target_id = 2,
			target_generation = 20,
			request_id = 100,
		},
	}

	apply_err := edit.apply_results(targets, context.allocator)
	testing.expect(t, errs.ok(apply_err))
	errs.destroy(&apply_err)
	expect_content(t, &first_doc, "Afirst")
	expect_content(t, &second_doc, "secondB")
	expect_selection(t, first_selection, 0, 1)
	expect_selection(t, second_selection, 6, 7)
	testing.expect(t, txn.doc_log_len(&first_doc) == 1)
	testing.expect(t, txn.doc_log_len(&second_doc) == 1)
	testing.expect(t, first_doc.log[0].grouping_key == 41 && second_doc.log[0].grouping_key == 41)
}

@(test)
test_multi_buffer_stale_generation_applies_nothing :: proc(t: ^testing.T) {
	first_doc, second_doc: txn.Doc
	init_doc(t, &first_doc, "first")
	init_doc(t, &second_doc, "second")
	defer txn.doc_destroy(&first_doc)
	defer txn.doc_destroy(&second_doc)
	first_selection, second_selection: txn.Selection
	first_history, second_history: address.Regex_History
	first_result := edit.Result{
		target_id = 1,
		target_generation = 10,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 0, data = transmute([]byte)string("A")}},
			after_selection = {anchor = 0, active = 1, affinity = .Right},
		}},
		selection = {anchor = 0, active = 1, affinity = .Right},
	}
	second_result := edit.Result{
		target_id = 2,
		target_generation = 20,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 6, data = transmute([]byte)string("B")}},
			after_selection = {anchor = 6, active = 7, affinity = .Right},
		}},
		selection = {anchor = 6, active = 7, affinity = .Right},
	}
	targets := []edit.Result_Target{
		{doc = &first_doc, selection = &first_selection, history = &first_history, result = &first_result, target_id = 1, target_generation = 10, request_id = 100},
		{doc = &second_doc, selection = &second_selection, history = &second_history, result = &second_result, target_id = 2, target_generation = 21, request_id = 100},
	}

	apply_err := edit.apply_results(targets, context.allocator)
	testing.expect(t, apply_err.kind == .Conflict)
	errs.destroy(&apply_err)
	expect_content(t, &first_doc, "first")
	expect_content(t, &second_doc, "second")
	expect_selection(t, first_selection, 0, 0)
	expect_selection(t, second_selection, 0, 0)
	testing.expect(t, txn.doc_log_len(&first_doc) == 0)
	testing.expect(t, txn.doc_log_len(&second_doc) == 0)
}

@(test)
test_multi_buffer_stale_revision_applies_nothing :: proc(t: ^testing.T) {
	first_doc, second_doc: txn.Doc
	init_doc(t, &first_doc, "first")
	init_doc(t, &second_doc, "second")
	defer txn.doc_destroy(&first_doc)
	defer txn.doc_destroy(&second_doc)
	first_selection, second_selection: txn.Selection
	first_history, second_history: address.Regex_History

	local_transaction := txn.Transaction{
		source = .Typing,
		base_revision = 0,
		ops = []txn.Operation{txn.Insert{pos = 0, data = transmute([]byte)string("!")}},
	}
	local_err := txn.doc_apply(&second_doc, &local_transaction, context.allocator)
	testing.expect(t, errs.ok(local_err))
	errs.destroy(&local_err)

	first_result := edit.Result{
		target_id = 1,
		target_generation = 10,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 0, data = transmute([]byte)string("A")}},
			after_selection = {anchor = 0, active = 1, affinity = .Right},
		}},
		selection = {anchor = 0, active = 1, affinity = .Right},
	}
	second_result := edit.Result{
		target_id = 2,
		target_generation = 20,
		request_id = 100,
		grouping_key = 41,
		batches = []edit.Transaction_Batch{{
			ops = []txn.Operation{txn.Insert{pos = 7, data = transmute([]byte)string("B")}},
			after_selection = {anchor = 7, active = 8, affinity = .Right},
		}},
		selection = {anchor = 7, active = 8, affinity = .Right},
	}
	targets := []edit.Result_Target{
		{doc = &first_doc, selection = &first_selection, history = &first_history, result = &first_result, target_id = 1, target_generation = 10, request_id = 100},
		{doc = &second_doc, selection = &second_selection, history = &second_history, result = &second_result, target_id = 2, target_generation = 20, request_id = 100},
	}

	apply_err := edit.apply_results(targets, context.allocator)
	testing.expect(t, apply_err.kind == .Conflict)
	errs.destroy(&apply_err)
	expect_content(t, &first_doc, "first")
	expect_content(t, &second_doc, "!second")
	expect_selection(t, first_selection, 0, 0)
	expect_selection(t, second_selection, 0, 0)
	testing.expect(t, txn.doc_log_len(&first_doc) == 0)
	testing.expect(t, txn.doc_log_len(&second_doc) == 1)
}
