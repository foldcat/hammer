package command

import "core:strings"

import errs "../errs"
import rope "../rope"
import txn "../txn"

MAX_COMMAND_BYTES :: 64 * 1024

Source_Kind :: enum u8 {
	Body,
	Global_Tag,
	Column_Tag,
	Window_Tag,
}

Source :: struct {
	kind:              Source_Kind,
	target_id:         u64,
	window_id:         u64,
	column_id:         u64,
	buffer_id:         u64,
	buffer_generation: u64,
	revision:          u64,
	selection:         txn.Selection,
	command_range:     rope.Byte_Range,
	// Borrowed from the source buffer; valid for the synchronous dispatch.
	file_path:         string,
}

Argument :: struct {
	valid:             bool,
	target_id:         u64,
	selection:         txn.Selection,
	buffer_id:         u64,
	generation:        u64,
	revision:          u64,
}

Context :: struct {
	source:         Source,
	argument:       Argument,
	argument_chord: bool,
}

Invocation :: struct {
	// Both strings borrow the input passed to parse.
	name:     string,
	argument: string,
}

Handler :: proc(ctx: ^Context, invocation: Invocation) -> errs.Error

Entry :: struct {
	name:    string,
	handler: Handler,
}

parse :: proc(text: string, allocator := context.allocator) -> (Invocation, errs.Error) {
	if len(text) > MAX_COMMAND_BYTES {
		return {}, errs.newf(
			.Resource_Limit,
			"command: text exceeds the %d-byte command budget",
			MAX_COMMAND_BYTES,
			allocator = allocator,
		)
	}
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return {}, errs.new(.Invalid_Input, "command: empty command", allocator = allocator)
	}
	for index in 0 ..< len(trimmed) {
		switch trimmed[index] {
		case ' ', '\t', '\r', '\n':
			return Invocation{
				name = trimmed[:index],
				argument = strings.trim_space(trimmed[index:]),
			}, {}
		}
	}
	return Invocation{name = trimmed}, {}
}

dispatch :: proc(registry: []Entry, invocation: Invocation, ctx: ^Context, allocator := context.allocator) -> (bool, errs.Error) {
	if ctx == nil {
		return false, errs.new(.Invalid_Input, "command: nil dispatch context", allocator = allocator)
	}
	for entry in registry {
		if entry.name != invocation.name {
			continue
		}
		if entry.handler == nil {
			return true, errs.newf(.Internal, "command: %s has no handler", invocation.name, allocator = allocator)
		}
		return true, entry.handler(ctx, invocation)
	}
	return false, errs.newf(.NotFound, "command: %s is not registered", invocation.name, allocator = allocator)
}
