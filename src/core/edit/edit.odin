package edit

import "core:unicode"
import "core:unicode/utf8"

import address "../address"
import errs "../errs"

MAX_EDIT_BYTES :: 64 * 1024
MAX_COMMANDS :: 128
MAX_MOVE_BYTES :: 64 * 1024 * 1024

Command_Kind :: enum u8 {
	Set_Dot,
	Append,
	Change,
	Insert,
	Delete,
	Move,
	Copy,
}

Command :: struct {
	kind:         Command_Kind,
	has_address:  bool,
	expression:   address.Expression,
	destination:  address.Expression,
	text_offset:  int,
	text_length:  int,
}

// Program owns its command and decoded-text arrays. Destroy it with the same
// allocator passed to parse; command_text returns a borrowed view into it.
Program :: struct {
	commands: [dynamic]Command,
	text:     [dynamic]u8,
}

Parser :: struct {
	text:    string,
	index:   int,
	program: Program,
}

parse :: proc(text: string, allocator := context.allocator) -> (Program, errs.Error) {
	if len(text) > MAX_EDIT_BYTES {
		return {}, errs.newf(
			.Resource_Limit,
			"edit: text exceeds the %d-byte command budget",
			MAX_EDIT_BYTES,
			allocator = allocator,
		)
	}
	parser := Parser{text = text}
	parser.program.commands = make([dynamic]Command, allocator)
	parser.program.text = make([dynamic]u8, allocator)
	if err := reserve(&parser.program.text, len(text)); err != .None {
		program_destroy(&parser.program, allocator)
		return {}, errs.newf(.Resource_Limit, "edit: reserving text storage failed: %v", err, allocator = allocator)
	}

	for {
		skip_horizontal(&parser)
		for !at_end(&parser) && parser.text[parser.index] == '\n' {
			parser.index += 1
			skip_horizontal(&parser)
		}
		if at_end(&parser) {
			break
		}

		command: Command
		if address_start(parser.text[parser.index]) {
			expression, consumed, err := address.parse_prefix(parser.text[parser.index:], allocator)
			if !errs.ok(err) {
				program_destroy(&parser.program, allocator)
				return {}, err
			}
			command.has_address = true
			command.expression = expression
			parser.index += consumed
			skip_horizontal(&parser)
		}
		if at_end(&parser) || parser.text[parser.index] == '\n' {
			if !command.has_address {
				program_destroy(&parser.program, allocator)
				return {}, errs.new(.Invalid_Input, "edit: expected a command", allocator = allocator)
			}
			command.kind = .Set_Dot
			if err := append_command(&parser, command, allocator); !errs.ok(err) {
				program_destroy(&parser.program, allocator)
				return {}, err
			}
			if !at_end(&parser) {
				parser.index += 1
			}
			continue
		}

		command_byte := parser.text[parser.index]
		parser.index += 1
		switch command_byte {
		case 'a', 'c', 'i':
			switch command_byte {
			case 'a':
				command.kind = .Append
			case 'c':
				command.kind = .Change
			case 'i':
				command.kind = .Insert
			}
			if err := parse_text(&parser, &command, allocator); !errs.ok(err) {
				program_destroy(&parser.program, allocator)
				return {}, err
			}
		case 'd':
			command.kind = .Delete
			if err := finish_line(&parser, allocator); !errs.ok(err) {
				program_destroy(&parser.program, allocator)
				return {}, err
			}
		case 'm', 't':
			command.kind = .Move if command_byte == 'm' else .Copy
			skip_horizontal(&parser)
			if at_end(&parser) || !address_start(parser.text[parser.index]) {
				program_destroy(&parser.program, allocator)
				return {}, errs.new(.Invalid_Input, "edit: move/copy requires a destination address", allocator = allocator)
			}
			destination, consumed, err := address.parse_prefix(parser.text[parser.index:], allocator)
			if !errs.ok(err) {
				program_destroy(&parser.program, allocator)
				return {}, err
			}
			if destination.nodes[destination.root].kind != .Simple {
				program_destroy(&parser.program, allocator)
				return {}, errs.new(.Invalid_Input, "edit: move/copy destination must be a simple address", allocator = allocator)
			}
			command.destination = destination
			parser.index += consumed
			if finish_err := finish_line(&parser, allocator); !errs.ok(finish_err) {
				program_destroy(&parser.program, allocator)
				return {}, finish_err
			}
		case:
			program_destroy(&parser.program, allocator)
			return {}, errs.newf(
				.Unsupported,
				"edit: command %q is not implemented by this subset",
				command_byte,
				allocator = allocator,
			)
		}
		if err := append_command(&parser, command, allocator); !errs.ok(err) {
			program_destroy(&parser.program, allocator)
			return {}, err
		}
	}
	return parser.program, {}
}

program_destroy :: proc(program: ^Program, allocator := context.allocator) {
	if program == nil {
		return
	}
	delete(program.commands[:], allocator)
	delete(program.text[:], allocator)
	program^ = {}
}

command_text :: proc(program: ^Program, command: Command) -> []byte {
	return program.text[command.text_offset:command.text_offset + command.text_length]
}

append_command :: proc(parser: ^Parser, command: Command, allocator := context.allocator) -> errs.Error {
	if len(parser.program.commands) >= MAX_COMMANDS {
		return errs.newf(.Resource_Limit, "edit: more than %d commands", MAX_COMMANDS, allocator = allocator)
	}
	if err := reserve(&parser.program.commands, len(parser.program.commands) + 1); err != .None {
		return errs.newf(.Resource_Limit, "edit: growing the command list failed: %v", err, allocator = allocator)
	}
	append(&parser.program.commands, command)
	return {}
}

address_start :: proc(c: u8) -> bool {
	return c == '.' || c == '$' || c == '+' || c == '-' || c == '#' || c == '/' || c == '?' ||
		c == ',' || c == ';' || (c >= '0' && c <= '9')
}

at_end :: proc(parser: ^Parser) -> bool {
	return parser.index >= len(parser.text)
}

skip_horizontal :: proc(parser: ^Parser) {
	for !at_end(parser) {
		switch parser.text[parser.index] {
		case ' ', '\t':
			parser.index += 1
		case:
			return
		}
	}
}

finish_line :: proc(parser: ^Parser, allocator := context.allocator) -> errs.Error {
	skip_horizontal(parser)
	if at_end(parser) {
		return {}
	}
	if parser.text[parser.index] != '\n' {
		return errs.newf(
			.Invalid_Input,
			"edit: unexpected byte %q at offset %d; expected a newline",
			parser.text[parser.index],
			parser.index,
			allocator = allocator,
		)
	}
	parser.index += 1
	return {}
}

parse_text :: proc(parser: ^Parser, command: ^Command, allocator := context.allocator) -> errs.Error {
	skip_horizontal(parser)
	command.text_offset = len(parser.program.text)
	if at_end(parser) {
		return errs.new(.Invalid_Input, "edit: text command requires a delimiter or multiline text", allocator = allocator)
	}
	if parser.text[parser.index] == '\n' {
		parser.index += 1
		return parse_multiline_text(parser, command, allocator)
	}

	delimiter, width := utf8.decode_rune_in_string(parser.text[parser.index:])
	if width == 0 || (delimiter == utf8.RUNE_ERROR && width == 1) ||
		!unicode.is_print(delimiter) || unicode.is_letter(delimiter) || unicode.is_number(delimiter) || delimiter == '\\' {
		return errs.newf(.Invalid_Input, "edit: invalid text delimiter at offset %d", parser.index, allocator = allocator)
	}
	delimiter_text := parser.text[parser.index:parser.index + width]
	parser.index += width
	for !at_end(parser) {
		if parser.text[parser.index] == '\n' {
			break
		}
		if parser.text[parser.index] == delimiter_text[0] && parser.index + width <= len(parser.text) &&
			parser.text[parser.index:parser.index + width] == delimiter_text {
			parser.index += width
			command.text_length = len(parser.program.text) - command.text_offset
			return finish_line(parser, allocator)
		}
		if parser.text[parser.index] != '\\' {
			append(&parser.program.text, parser.text[parser.index])
			parser.index += 1
			continue
		}
		if parser.index + 1 >= len(parser.text) {
			return errs.new(.Invalid_Input, "edit: trailing backslash in text", allocator = allocator)
		}
		next := parser.text[parser.index + 1]
		if next == '\n' {
			append(&parser.program.text, '\\')
			parser.index += 1
			continue
		}
		if next == 'n' {
			append(&parser.program.text, '\n')
			parser.index += 2
			continue
		}
		if next == '\\' {
			append(&parser.program.text, '\\')
			parser.index += 2
			continue
		}
		if next == delimiter_text[0] && parser.index + 1 + width <= len(parser.text) &&
			parser.text[parser.index + 1:parser.index + 1 + width] == delimiter_text {
			append(&parser.program.text, ..transmute([]byte)delimiter_text)
			parser.index += 1 + width
			continue
		}
		append(&parser.program.text, '\\')
		parser.index += 1
	}
	command.text_length = len(parser.program.text) - command.text_offset
	return finish_line(parser, allocator)
}

parse_multiline_text :: proc(parser: ^Parser, command: ^Command, allocator := context.allocator) -> errs.Error {
	for !at_end(parser) {
		line_start := parser.index
		for !at_end(parser) && parser.text[parser.index] != '\n' {
			parser.index += 1
		}
		line := parser.text[line_start:parser.index]
		if line == "." {
			if !at_end(parser) {
				parser.index += 1
			}
			command.text_length = len(parser.program.text) - command.text_offset
			return {}
		}
		append(&parser.program.text, ..transmute([]byte)line)
		if !at_end(parser) {
			append(&parser.program.text, '\n')
			parser.index += 1
		}
	}
	return errs.new(.Invalid_Input, "edit: multiline text is missing its terminating dot", allocator = allocator)
}
