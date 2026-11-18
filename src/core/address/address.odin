package address

import "base:runtime"

import errs "../errs"

MAX_ADDRESS_BYTES :: 4096
MAX_OPERATIONS :: 128
MAX_RANGE_DEPTH :: 32
MAX_NODES :: 2 * MAX_RANGE_DEPTH + 1

Direction :: enum u8 {
	Absolute,
	Forward,
	Backward,
}

Operation_Kind :: enum u8 {
	Dot,
	End,
	Line,
	Character,
}

Operation :: struct {
	kind:      Operation_Kind,
	direction: Direction,
	count:     int,
}

Node_Kind :: enum u8 {
	Simple,
	Range,
}

Separator :: enum u8 {
	None,
	Comma,
	Semicolon,
}

Node :: struct {
	kind:            Node_Kind,
	first_operation: int,
	operation_count: int,
	left:            int,
	right:           int,
	separator:       Separator,
}

Expression :: struct {
	nodes:           [MAX_NODES]Node,
	operations:      [MAX_OPERATIONS]Operation,
	node_count:      int,
	operation_count: int,
	root:            int,
}

Parser :: struct {
	text:      string,
	index:     int,
	allocator: runtime.Allocator,
	result:    Expression,
}

parse :: proc(text: string, allocator := context.allocator) -> (Expression, errs.Error) {
	if len(text) > MAX_ADDRESS_BYTES {
		return {}, errs.newf(
			.Resource_Limit,
			"address: text exceeds the %d-byte address budget",
			MAX_ADDRESS_BYTES,
			allocator = allocator,
		)
	}
	parser := Parser{text = text, allocator = allocator}
	skip_blanks(&parser)
	if at_end(&parser) {
		return {}, errs.new(.Invalid_Input, "address: empty address", allocator = allocator)
	}
	root, err := parse_compound(&parser, 0, false)
	if !errs.ok(err) {
		return {}, err
	}
	skip_blanks(&parser)
	if !at_end(&parser) {
		switch parser.text[parser.index] {
		case '/', '?':
			return {}, errs.new(.Unsupported, "address: regular expressions are implemented by M08.03", allocator = allocator)
		case:
			return {}, errs.newf(
				.Invalid_Input,
				"address: unexpected byte %q at offset %d",
				parser.text[parser.index],
				parser.index,
				allocator = allocator,
			)
		}
	}
	parser.result.root = root
	return parser.result, {}
}

at_end :: proc(parser: ^Parser) -> bool {
	return parser.index >= len(parser.text)
}

skip_blanks :: proc(parser: ^Parser) {
	for !at_end(parser) {
		switch parser.text[parser.index] {
		case ' ', '\t':
			parser.index += 1
		case:
			return
		}
	}
}

simple_start :: proc(c: u8) -> bool {
	return c == '.' || c == '$' || c == '+' || c == '-' || c == '#' || (c >= '0' && c <= '9')
}

add_operation :: proc(parser: ^Parser, operation: Operation) -> errs.Error {
	if parser.result.operation_count >= MAX_OPERATIONS {
		return errs.newf(
			.Resource_Limit,
			"address: more than %d simple-address operations",
			MAX_OPERATIONS,
			allocator = parser.allocator,
		)
	}
	parser.result.operations[parser.result.operation_count] = operation
	parser.result.operation_count += 1
	return {}
}

add_node :: proc(parser: ^Parser, node: Node) -> (int, errs.Error) {
	if parser.result.node_count >= MAX_NODES {
		return -1, errs.new(.Resource_Limit, "address: too many address nodes", allocator = parser.allocator)
	}
	index := parser.result.node_count
	parser.result.nodes[index] = node
	parser.result.node_count += 1
	return index, {}
}

parse_number :: proc(parser: ^Parser) -> (int, errs.Error) {
	value := u64(0)
	max_int := u64(~uint(0) >> 1)
	for !at_end(parser) {
		c := parser.text[parser.index]
		if c < '0' || c > '9' {
			break
		}
		digit := u64(c - '0')
		if value > (max_int - digit) / 10 {
			return 0, errs.new(.Resource_Limit, "address: decimal number exceeds the integer range", allocator = parser.allocator)
		}
		value = value * 10 + digit
		parser.index += 1
	}
	return int(value), {}
}

parse_simple :: proc(parser: ^Parser) -> (int, errs.Error) {
	skip_blanks(parser)
	if at_end(parser) || !simple_start(parser.text[parser.index]) {
		return -1, {}
	}
	first_operation := parser.result.operation_count
	pending := Direction.Absolute
	last_sign := false
	if parser.text[parser.index] == '.' || parser.text[parser.index] == '$' {
		kind := Operation_Kind.Dot if parser.text[parser.index] == '.' else Operation_Kind.End
		parser.index += 1
		if err := add_operation(parser, {kind = kind}); !errs.ok(err) {
			return -1, err
		}
	}
	for {
		skip_blanks(parser)
		if at_end(parser) {
			break
		}
		c := parser.text[parser.index]
		if c == '+' || c == '-' {
			if last_sign {
				if err := add_operation(parser, {kind = .Line, direction = pending, count = 1}); !errs.ok(err) {
					return -1, err
				}
			}
			pending = Direction.Forward if c == '+' else Direction.Backward
			last_sign = true
			parser.index += 1
			continue
		}
		if c == '#' || (c >= '0' && c <= '9') {
			kind := Operation_Kind.Line
			if c == '#' {
				kind = .Character
				parser.index += 1
				if at_end(parser) || parser.text[parser.index] < '0' || parser.text[parser.index] > '9' {
					return -1, errs.newf(
						.Invalid_Input,
						"address: # at offset %d requires a decimal number",
						parser.index - 1,
						allocator = parser.allocator,
					)
				}
			}
			direction := pending if last_sign else (Direction.Forward if parser.result.operation_count > first_operation else Direction.Absolute)
			count, err := parse_number(parser)
			if !errs.ok(err) {
				return -1, err
			}
			if add_err := add_operation(parser, {kind = kind, direction = direction, count = count}); !errs.ok(add_err) {
				return -1, add_err
			}
			pending = .Absolute
			last_sign = false
			continue
		}
		break
	}
	if last_sign {
		if err := add_operation(parser, {kind = .Line, direction = pending, count = 1}); !errs.ok(err) {
			return -1, err
		}
	}
	return add_node(parser, {
		kind = .Simple,
		first_operation = first_operation,
		operation_count = parser.result.operation_count - first_operation,
		left = -1,
		right = -1,
	})
}

parse_compound :: proc(parser: ^Parser, depth: int, allow_empty: bool) -> (int, errs.Error) {
	if depth > MAX_RANGE_DEPTH {
		return -1, errs.newf(
			.Resource_Limit,
			"address: range nesting exceeds %d levels",
			MAX_RANGE_DEPTH,
			allocator = parser.allocator,
		)
	}
	skip_blanks(parser)
	if at_end(parser) {
		if allow_empty {
			return -1, {}
		}
		return -1, errs.new(.Invalid_Input, "address: missing address", allocator = parser.allocator)
	}
	if parser.text[parser.index] == '/' || parser.text[parser.index] == '?' {
		return -1, errs.new(.Unsupported, "address: regular expressions are implemented by M08.03", allocator = parser.allocator)
	}
	left, err := parse_simple(parser)
	if !errs.ok(err) {
		return -1, err
	}
	skip_blanks(parser)
	if !at_end(parser) && (parser.text[parser.index] == ',' || parser.text[parser.index] == ';') {
		separator := Separator.Comma if parser.text[parser.index] == ',' else Separator.Semicolon
		parser.index += 1
		skip_blanks(parser)
		if !at_end(parser) && (parser.text[parser.index] == ',' || parser.text[parser.index] == ';') {
			return -1, errs.newf(
				.Invalid_Input,
				"address: consecutive range separator at offset %d",
				parser.index,
				allocator = parser.allocator,
			)
		}
		right, right_err := parse_compound(parser, depth + 1, true)
		if !errs.ok(right_err) {
			return -1, right_err
		}
		return add_node(parser, {kind = .Range, left = left, right = right, separator = separator})
	}
	if left < 0 {
		return -1, errs.newf(
			.Invalid_Input,
			"address: expected an address at offset %d",
			parser.index,
			allocator = parser.allocator,
		)
	}
	return left, {}
}
