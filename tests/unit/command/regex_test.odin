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

@(test)
test_raku_program_command_and_declarative_line_modes :: proc(t: ^testing.T) {
	plain, plain_err := command.raku_program_command("/sandbox/raku", "", "/sandbox/program.raku", context.allocator)
	expect_ok(t, plain_err)
	defer command.raku_program_command_destroy(plain, context.allocator)
	testing.expect(t, len(plain) == 2 && plain[0] == "/sandbox/raku" && plain[1] == "/sandbox/program.raku")

	lines, lines_err := command.raku_program_command("/sandbox/raku", "-p", "/sandbox/program.raku", context.allocator)
	expect_ok(t, lines_err)
	defer command.raku_program_command_destroy(lines, context.allocator)
	testing.expect(t, len(lines) == 3 && lines[1] == "-p" && lines[2] == "/sandbox/program.raku")
	_, invalid_err := command.raku_program_command("/sandbox/raku", "-e", "/sandbox/program.raku", context.allocator)
	expect_kind(t, invalid_err, .Invalid_Input)

	definition, parse_err := command.filter_parse_definition(
		"name: upper\nengine: raku\nrouting: replace-selection\nraku: -p\nbody: $_ = $_.uc\n",
		"upper.filter",
		.User,
		context.allocator,
	)
	expect_ok(t, parse_err)
	testing.expect(t, definition.raku_mode == "-p")
	registry: command.Filter_Registry
	expect_ok(t, command.filter_registry_init(&registry, {}, context.allocator))
	defer command.filter_registry_destroy(&registry)
	expect_ok(t, command.filter_registry_register(&registry, definition))
	registered := command.filter_registry_find(&registry, "upper")
	testing.expect(t, registered != nil && registered.raku_mode == "-p")

	invalid := []string{
		"name: bad\nengine: raku\nrouting: discard\nraku: -e\nbody: x\n",
		"name: bad\nengine: engine\nrouting: discard\nraku: -n\nbody: x\n",
		"name: bad\nengine: raku\nrouting: discard\nraku: -n\nraku: -p\nbody: x\n",
	}
	for text in invalid {
		_, err := command.filter_parse_definition(text, "invalid.filter", .User, context.allocator)
		expect_kind(t, err, .Invalid_Input)
	}
}
