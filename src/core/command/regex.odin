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

raku_regex_command_destroy :: proc(argv: []string, allocator := context.allocator) {
	for argument in argv {
		delete(argument, allocator)
	}
	delete(argv, allocator)
}
