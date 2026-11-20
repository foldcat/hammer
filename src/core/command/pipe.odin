package command

import "core:strings"

import errs "../errs"

// External-command routing (SPECS.md §12.4). A command text that begins with
// `|`, `<`, or `>` routes the current body selection through an external shell
// process instead of the built-in registry; a plain command that matches no
// built-in or filter falls through to the same shell path. The Acme meanings:
//
//   - `|command`: pipe — selection becomes stdin, stdout replaces the selection.
//   - `<command`: replace — stdin is empty, stdout replaces the selection.
//   - `>command`: feed — selection becomes stdin, stdout goes to +Errors.
//   - `command` (plain): stdin is empty, stdout/stderr go to +Errors.
//
// The editor runs every external command through a shell (`sh -c` on Unix,
// `cmd /c` on Windows) — there is deliberately no "direct exec" fallback: the
// user typed the command and chose to run it, so shell interpretation is the
// explicit, expected behavior. Only routing and the command *text* are parsed
// here; spawning and output routing live in the editor layer.

MAX_PIPE_COMMAND_BYTES :: MAX_COMMAND_BYTES

Pipe_Routing :: enum u8 {
	Pipe,    // |command
	Replace, // <command
	Feed,    // >command
	Plain,   // command (no prefix)
}

pipe_routing_name :: proc(routing: Pipe_Routing) -> string {
	switch routing {
	case .Pipe:
		return "pipe"
	case .Replace:
		return "replace"
	case .Feed:
		return "feed"
	case .Plain:
		return "plain"
	}
	return "unknown"
}

// pipe_routing_prefix returns the one-byte marker for a routing, or 0 for a
// plain command.
pipe_routing_prefix :: proc(routing: Pipe_Routing) -> u8 {
	switch routing {
	case .Pipe:
		return '|'
	case .Replace:
		return '<'
	case .Feed:
		return '>'
	case .Plain:
		return 0
	}
	return 0
}

// pipe_parse detects a leading routing prefix after any leading whitespace and
// returns the routing plus the trimmed remaining command text. The returned
// command string borrows `text`. ok is false when there is no prefix.
pipe_parse :: proc(text: string) -> (routing: Pipe_Routing, command: string, ok: bool) {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return {}, "", false
	}
	switch trimmed[0] {
	case '|':
		return .Pipe, strings.trim_space(trimmed[1:]), true
	case '<':
		return .Replace, strings.trim_space(trimmed[1:]), true
	case '>':
		return .Feed, strings.trim_space(trimmed[1:]), true
	}
	return {}, "", false
}

// pipe_default_shell returns the platform shell used when the config does not
// override it.
pipe_default_shell :: proc() -> string {
	when ODIN_OS == .Windows {
		return "cmd.exe"
	} else {
		return "sh"
	}
}

// pipe_shell_command builds the argv that invokes `shell` with `command` as a
// single program argument using the platform shell flag. The caller owns the
// returned slice and every element and must release them with
// pipe_argv_destroy.
pipe_shell_command :: proc(shell, command: string, allocator := context.allocator) -> ([]string, errs.Error) {
	when ODIN_OS == .Windows {
		flag := "/c"
	} else {
		flag := "-c"
	}
	argv, alloc_err := make([]string, 3, allocator)
	if alloc_err != nil {
		return nil, errs.new(.Resource_Limit, "pipe: cannot allocate shell command vector", allocator = allocator)
	}
	argv[0], alloc_err = strings.clone(shell, allocator)
	if alloc_err == nil {
		argv[1], alloc_err = strings.clone(flag, allocator)
	}
	if alloc_err == nil {
		argv[2], alloc_err = strings.clone(command, allocator)
	}
	if alloc_err != nil || argv[0] == "" || argv[1] == "" || argv[2] == "" {
		pipe_argv_destroy(argv, allocator)
		return nil, errs.new(.Resource_Limit, "pipe: cannot copy shell command vector", allocator = allocator)
	}
	return argv, {}
}

// pipe_argv_destroy releases an owned vector produced by pipe_shell_command.
// It is safe on nil.
pipe_argv_destroy :: proc(argv: []string, allocator := context.allocator) {
	for arg in argv {
		delete(arg, allocator)
	}
	delete(argv, allocator)
}
