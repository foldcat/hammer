package command

import "core:fmt"
import "core:strings"

import errs "../errs"

RAKU_REGEX_PROGRAM :: `my $text = $*IN.slurp;
my $pattern = @*ARGS[0];
my $start-byte = @*ARGS[1].Int;
my $start = $text.encode("UTF-8").subbuf(0, $start-byte).decode("UTF-8").chars;
my $match = $text.substr($start).match(/<$pattern>/);
if !$match.defined {
    $match = $text.substr(0, $start).match(/<$pattern>/);
    if !$match.defined { exit 4; };
    my $start-offset = $match.prematch.encode("UTF-8").bytes;
    say "$start-offset " ~ ($start-offset + $match.Str.encode("UTF-8").bytes);
} else {
    my $start-offset = $text.substr(0, $start).encode("UTF-8").bytes + $match.prematch.encode("UTF-8").bytes;
    say "$start-offset " ~ ($start-offset + $match.Str.encode("UTF-8").bytes);
}`

// raku_regex_command builds the fixed external-search adapter. Pattern and
// starting byte offset are separate argv entries; no shell interprets them.
// The caller owns the vector and its strings.
raku_regex_command :: proc(engine_path, pattern: string, start_byte: int, allocator := context.allocator) -> ([]string, errs.Error) {
	if engine_path == "" || start_byte < 0 {
		return nil, errs.new(.Invalid_Input, "regex: Raku search requires an engine and nonnegative start offset", allocator = allocator)
	}
	start := fmt.aprintf("%d", start_byte, allocator = allocator)
	if start == "" {
		return nil, errs.new(.Resource_Limit, "regex: cannot format Raku search offset", allocator = allocator)
	}
	argv, alloc_err := make([]string, 5, allocator)
	if alloc_err != nil {
		delete(start, allocator)
		return nil, errs.new(.Resource_Limit, "regex: cannot allocate Raku search command", allocator = allocator)
	}
	argv[0] = strings.clone(engine_path, allocator)
	argv[1] = strings.clone("-e", allocator)
	argv[2] = strings.clone(RAKU_REGEX_PROGRAM, allocator)
	argv[3] = strings.clone(pattern, allocator)
	argv[4] = start
	if argv[0] == "" || argv[1] == "" || argv[2] == "" || (argv[3] == "" && pattern != "") || argv[4] == "" {
		raku_regex_command_destroy(argv, allocator)
		return nil, errs.new(.Resource_Limit, "regex: cannot copy Raku search command", allocator = allocator)
	}
	return argv, {}
}

raku_program_mode_valid :: proc(mode: string) -> bool {
	return mode == "" || mode == "-n" || mode == "-p"
}

// raku_program_command invokes a source file directly, without a shell. The
// optional mode is one declarative Raku argument (-n or -p), not a command line.
raku_program_command :: proc(engine_path, mode, program_path: string, allocator := context.allocator) -> ([]string, errs.Error) {
	if engine_path == "" || program_path == "" || !raku_program_mode_valid(mode) {
		return nil, errs.new(.Invalid_Input, "raku: invalid program command", allocator = allocator)
	}
	path_index := 1
	vector_length := 2
	if mode != "" {
		path_index = 2
		vector_length = 3
	}
	argv, alloc_err := make([]string, vector_length, allocator)
	if alloc_err != nil {
		return nil, errs.new(.Resource_Limit, "raku: cannot allocate program command", allocator = allocator)
	}
	argv[0] = strings.clone(engine_path, allocator)
	if mode != "" {
		argv[1] = strings.clone(mode, allocator)
	}
	argv[path_index] = strings.clone(program_path, allocator)
	if argv[0] == "" || (mode != "" && argv[1] == "") || argv[path_index] == "" {
		raku_program_command_destroy(argv, allocator)
		return nil, errs.new(.Resource_Limit, "raku: cannot copy program command", allocator = allocator)
	}
	return argv, {}
}

raku_program_command_destroy :: proc(argv: []string, allocator := context.allocator) {
	for argument in argv {
		delete(argument, allocator)
	}
	delete(argv, allocator)
}

raku_regex_command_destroy :: proc(argv: []string, allocator := context.allocator) {
	for argument in argv {
		delete(argument, allocator)
	}
	delete(argv, allocator)
}
