package command_test

import "core:testing"

import command "hammer:core/command"
import errs "hammer:core/errs"

expect_ok :: proc(t: ^testing.T, err: errs.Error) {
	if !errs.ok(err) {
		description := errs.describe(err, context.allocator)
		testing.expectf(t, false, "unexpected error: %s", description)
		delete(description, context.allocator)
		local := err
		errs.destroy(&local)
	}
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got error %v, expected %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

@(test)
test_parse_borrows_name_and_remainder :: proc(t: ^testing.T) {
	input := " \tLook  alpha beta\r\n "
	invocation, err := command.parse(input, context.allocator)
	expect_ok(t, err)
	testing.expect(t, invocation.name == "Look")
	testing.expect(t, invocation.argument == "alpha beta")

	invocation, err = command.parse("Put", context.allocator)
	expect_ok(t, err)
	testing.expect(t, invocation.name == "Put" && invocation.argument == "")
}

@(test)
test_parse_rejects_empty_and_oversized_input :: proc(t: ^testing.T) {
	_, err := command.parse(" \t\r\n", context.allocator)
	expect_kind(t, err, .Invalid_Input)

	input := make([]byte, command.MAX_COMMAND_BYTES + 1, context.allocator)
	defer delete(input, context.allocator)
	_, err = command.parse(string(input), context.allocator)
	expect_kind(t, err, .Resource_Limit)
}

verify_context_handler :: proc(ctx: ^command.Context, invocation: command.Invocation) -> errs.Error {
	source := ctx.source
	argument := ctx.argument
	valid := invocation.name == "Look" && invocation.argument == "needle" &&
		source.kind == .Window_Tag && source.target_id == 2007 && source.window_id == 7 &&
		source.column_id == 3 && source.buffer_id == 2007 && source.buffer_generation == 1 &&
		source.revision == 12 && source.selection.anchor == 4 && source.selection.active == 9 &&
		source.command_range.start == 2 && source.command_range.end == 11 &&
		source.file_path == "buffer.txt" && argument.valid && argument.target_id == 3008 &&
		argument.buffer_id == 8 && argument.generation == 2 && argument.revision == 19 &&
		argument.selection.anchor == 1 && argument.selection.active == 5 && ctx.argument_chord
	if !valid {
		return errs.new(.Internal, "command test: context changed during dispatch", allocator = context.allocator)
	}
	return {}
}

reject_handler :: proc(ctx: ^command.Context, invocation: command.Invocation) -> errs.Error {
	return errs.new(.Internal, "command test: wrong registry entry dispatched", allocator = context.allocator)
}

@(test)
test_dispatch_routes_exact_name_with_complete_context :: proc(t: ^testing.T) {
	ctx := command.Context{
		source = {
			kind = .Window_Tag,
			target_id = 2007,
			window_id = 7,
			column_id = 3,
			buffer_id = 2007,
			buffer_generation = 1,
			revision = 12,
			selection = {anchor = 4, active = 9, affinity = .Right},
			command_range = {start = 2, end = 11},
			file_path = "buffer.txt",
		},
		argument = {
			valid = true,
			target_id = 3008,
			selection = {anchor = 1, active = 5, affinity = .Left},
			buffer_id = 8,
			generation = 2,
			revision = 19,
		},
		argument_chord = true,
	}
	registry := []command.Entry{
		{name = "Look", handler = verify_context_handler},
		{name = "Del", handler = reject_handler},
	}
	invocation, err := command.parse("Look needle", context.allocator)
	expect_ok(t, err)
	handled, dispatch_err := command.dispatch(registry, invocation, &ctx, context.allocator)
	testing.expect(t, handled)
	expect_ok(t, dispatch_err)
}

@(test)
test_dispatch_rejects_unknown_missing_handler_and_nil_context :: proc(t: ^testing.T) {
	ctx: command.Context
	invocation := command.Invocation{name = "put"}
	handled, err := command.dispatch(nil, invocation, &ctx, context.allocator)
	testing.expect(t, !handled)
	expect_kind(t, err, .NotFound)

	registry := []command.Entry{{name = "put", handler = nil}}
	handled, err = command.dispatch(registry, invocation, &ctx, context.allocator)
	testing.expect(t, handled)
	expect_kind(t, err, .Internal)

	registry = []command.Entry{{name = "put", handler = reject_handler}}
	handled, err = command.dispatch(registry, invocation, &ctx, context.allocator)
	testing.expect(t, handled)
	expect_kind(t, err, .Internal)

	invocation.name = "Look"
	registry = []command.Entry{{name = "Look", handler = verify_context_handler}}
	handled, err = command.dispatch(registry, invocation, nil, context.allocator)
	testing.expect(t, !handled)
	expect_kind(t, err, .Invalid_Input)
}
