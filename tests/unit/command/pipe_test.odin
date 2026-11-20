package command_test

import "core:testing"

import command "hammer:core/command"

@(test)
test_pipe_parse_detects_routing_prefix :: proc(t: ^testing.T) {
	routing, text, ok := command.pipe_parse("|grep foo")
	testing.expect(t, ok && routing == .Pipe && text == "grep foo")

	routing, text, ok = command.pipe_parse("  <  cat -n ")
	testing.expect(t, ok && routing == .Replace && text == "cat -n")

	routing, text, ok = command.pipe_parse("\t>sort\t")
	testing.expect(t, ok && routing == .Feed && text == "sort")

	_, _, ok = command.pipe_parse("grep")
	testing.expect(t, !ok)
	_, _, ok = command.pipe_parse("")
	testing.expect(t, !ok)
	_, _, ok = command.pipe_parse("   ")
	testing.expect(t, !ok)

	_, text, ok = command.pipe_parse("|")
	testing.expect(t, ok && text == "")
}

@(test)
test_pipe_shell_command_builds_vector :: proc(t: ^testing.T) {
	argv, err := command.pipe_shell_command("sh", "grep foo", context.allocator)
	defer command.pipe_argv_destroy(argv, context.allocator)
	expect_ok(t, err)
	testing.expect(t, len(argv) == 3 && argv[0] == "sh" && argv[2] == "grep foo")
	when ODIN_OS == .Windows {
		testing.expect(t, argv[1] == "/c")
	} else {
		testing.expect(t, argv[1] == "-c")
	}
}

@(test)
test_pipe_default_shell_is_platform_default :: proc(t: ^testing.T) {
	shell := command.pipe_default_shell()
	when ODIN_OS == .Windows {
		testing.expect(t, shell == "cmd.exe")
	} else {
		testing.expect(t, shell == "sh")
	}
}
