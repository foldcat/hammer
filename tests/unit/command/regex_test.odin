package command_test

import "core:strings"
import "core:testing"

import command "hammer:core/command"

@(test)
test_raku_regex_command_separates_program_pattern_and_offset :: proc(t: ^testing.T) {
	argv, err := command.raku_regex_command("/sandbox/raku", "a/b (c+)", 23, context.allocator)
	expect_ok(t, err)
	defer command.raku_regex_command_destroy(argv, context.allocator)
	testing.expect(t, len(argv) == 5)
	testing.expect(t, argv[0] == "/sandbox/raku" && argv[1] == "-e")
	testing.expect(t, argv[2] == command.RAKU_REGEX_PROGRAM)
	testing.expect(t, argv[3] == "a/b (c+)" && argv[4] == "23")
	testing.expect(t, strings.contains(argv[2], "$*IN.slurp"))
	testing.expect(t, strings.contains(argv[2], "encode(\"UTF-8\")"))

	empty_argv, empty_err := command.raku_regex_command("/sandbox/raku", "", 0, context.allocator)
	expect_ok(t, empty_err)
	defer command.raku_regex_command_destroy(empty_argv, context.allocator)
	testing.expect(t, len(empty_argv) == 5 && empty_argv[3] == "" && empty_argv[4] == "0")

	_, missing_err := command.raku_regex_command("", "x", 0, context.allocator)
	expect_kind(t, missing_err, .Invalid_Input)
	_, negative_err := command.raku_regex_command("raku", "x", -1, context.allocator)
	expect_kind(t, negative_err, .Invalid_Input)
}
