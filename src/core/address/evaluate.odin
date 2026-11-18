package address

import "base:runtime"

import errs "../errs"
import rope "../rope"

LINE_SCAN_BYTES :: 16 * 1024

evaluate :: proc(
	tree: ^rope.Tree,
	expression: ^Expression,
	dot: rope.Byte_Range,
	allocator := context.allocator,
) -> (rope.Byte_Range, errs.Error) {
	if tree == nil || expression == nil {
		return {}, errs.new(.Invalid_Input, "address: nil tree or expression", allocator = allocator)
	}
	total := rope.tree_byte_count(tree)
	if dot.start < 0 || dot.end < dot.start || dot.end > total {
		return {}, errs.newf(
			.Invalid_Input,
			"address: dot [%d, %d) outside [0, %d]",
			dot.start,
			dot.end,
			total,
			allocator = allocator,
		)
	}
	if expression.node_count <= 0 || expression.root < 0 || expression.root >= expression.node_count {
		return {}, errs.new(.Invalid_Input, "address: empty or invalid expression", allocator = allocator)
	}
	return eval_node(tree, expression, expression.root, dot, 0, allocator)
}

eval_node :: proc(
	tree: ^rope.Tree,
	expression: ^Expression,
	node_index: int,
	dot: rope.Byte_Range,
	depth: int,
	allocator: runtime.Allocator,
) -> (rope.Byte_Range, errs.Error) {
	if depth > MAX_RANGE_DEPTH {
		return {}, errs.new(.Resource_Limit, "address: evaluation nesting is too deep", allocator = allocator)
	}
	if node_index < 0 || node_index >= expression.node_count {
		return {}, errs.new(.Invalid_Input, "address: invalid expression node", allocator = allocator)
	}
	node := expression.nodes[node_index]
	switch node.kind {
	case .Simple:
		if node.first_operation < 0 || node.operation_count <= 0 ||
			node.first_operation + node.operation_count > expression.operation_count {
			return {}, errs.new(.Invalid_Input, "address: invalid operation span", allocator = allocator)
		}
		current := dot
		for index in node.first_operation ..< node.first_operation + node.operation_count {
			operation := expression.operations[index]
			next: rope.Byte_Range
			err: errs.Error
			switch operation.kind {
			case .Dot:
				next = dot
			case .End:
				total := rope.tree_byte_count(tree)
				next = {start = total, end = total}
			case .Line:
				next, err = line_address(tree, current, operation.count, operation.direction, allocator)
			case .Character:
				next, err = character_address(tree, current, operation.count, operation.direction, allocator)
			}
			if !errs.ok(err) {
				return {}, err
			}
			if next.start < 0 || next.end < next.start || next.end > rope.tree_byte_count(tree) {
				return {}, address_out_of_range(allocator)
			}
			current = next
		}
		return current, {}
	case .Range:
		left := rope.Byte_Range{}
		err: errs.Error
		if node.left >= 0 {
			left, err = eval_node(tree, expression, node.left, dot, depth + 1, allocator)
			if !errs.ok(err) {
				return {}, err
			}
		}
		right_dot := dot
		if node.separator == .Semicolon {
			right_dot = left
		}
		total := rope.tree_byte_count(tree)
		right := rope.Byte_Range{start = total, end = total}
		if node.right >= 0 {
			right, err = eval_node(tree, expression, node.right, right_dot, depth + 1, allocator)
			if !errs.ok(err) {
				return {}, err
			}
		}
		if left.start > right.end {
			return {}, errs.newf(
				.Invalid_Input,
				"address: range starts at %d after its end at %d",
				left.start,
				right.end,
				allocator = allocator,
			)
		}
		return rope.Byte_Range{start = left.start, end = right.end}, {}
	}
	return {}, errs.new(.Invalid_Input, "address: unknown expression node", allocator = allocator)
}

address_out_of_range :: proc(allocator: runtime.Allocator) -> errs.Error {
	return errs.new(.NotFound, "address: address out of range", allocator = allocator)
}

character_address :: proc(
	tree: ^rope.Tree,
	current: rope.Byte_Range,
	count: int,
	direction: Direction,
	allocator: runtime.Allocator,
) -> (rope.Byte_Range, errs.Error) {
	if count < 0 {
		return {}, errs.new(.Invalid_Input, "address: negative character count", allocator = allocator)
	}
	total := rope.tree_scalar_count(tree)
	target := count
	if direction != .Absolute {
		position := current.end if direction == .Forward else current.start
		base, err := exact_scalar_at_byte(tree, position, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if direction == .Forward {
			if count > total - base {
				return {}, address_out_of_range(allocator)
			}
			target = base + count
		} else {
			if count > base {
				return {}, address_out_of_range(allocator)
			}
			target = base - count
		}
	}
	if target < 0 || target > total {
		return {}, address_out_of_range(allocator)
	}
	position, err := rope.tree_scalar_to_byte(tree, rope.Scalar_Index(target), allocator)
	if !errs.ok(err) {
		return {}, err
	}
	return rope.Byte_Range{start = position, end = position}, {}
}

exact_scalar_at_byte :: proc(tree: ^rope.Tree, position: int, allocator: runtime.Allocator) -> (int, errs.Error) {
	scalar, err := rope.tree_byte_to_scalar(tree, position, allocator)
	if !errs.ok(err) {
		return 0, err
	}
	start, start_err := rope.tree_scalar_to_byte(tree, scalar, allocator)
	if !errs.ok(start_err) {
		return 0, start_err
	}
	if start != position {
		return 0, errs.newf(
			.Invalid_Input,
			"address: byte offset %d is inside a Unicode character",
			position,
			allocator = allocator,
		)
	}
	return int(scalar), {}
}

line_address :: proc(
	tree: ^rope.Tree,
	current: rope.Byte_Range,
	count: int,
	direction: Direction,
	allocator: runtime.Allocator,
) -> (rope.Byte_Range, errs.Error) {
	if count < 0 {
		return {}, errs.new(.Invalid_Input, "address: negative line count", allocator = allocator)
	}
	switch direction {
	case .Absolute:
		return absolute_line(tree, count, allocator)
	case .Forward:
		return forward_line(tree, current, count, allocator)
	case .Backward:
		return backward_line(tree, current, count, allocator)
	}
	return {}, errs.new(.Invalid_Input, "address: unknown line direction", allocator = allocator)
}

absolute_line :: proc(tree: ^rope.Tree, count: int, allocator: runtime.Allocator) -> (rope.Byte_Range, errs.Error) {
	if count == 0 {
		return {}, {}
	}
	start := 0
	for line := 1; line < count; line += 1 {
		after, found, err := find_next_lf(tree, start, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if !found {
			return {}, address_out_of_range(allocator)
		}
		start = after
	}
	end, found, err := find_next_lf(tree, start, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	if !found {
		end = rope.tree_byte_count(tree)
	}
	return rope.Byte_Range{start = start, end = end}, {}
}

forward_line :: proc(
	tree: ^rope.Tree,
	current: rope.Byte_Range,
	count: int,
	allocator: runtime.Allocator,
) -> (rope.Byte_Range, errs.Error) {
	total := rope.tree_byte_count(tree)
	if count == 0 {
		if current.end == 0 {
			return {}, {}
		}
		end, found, err := find_next_lf(tree, current.end - 1, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if !found {
			end = total
		}
		return rope.Byte_Range{start = current.end, end = end}, {}
	}
	start := 0
	remaining := count - 1
	if current.end > 0 {
		previous, err := byte_at(tree, current.end - 1, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if previous == '\n' {
			start = current.end
		} else {
			after, found, next_err := find_next_lf(tree, current.end, allocator)
			if !errs.ok(next_err) {
				return {}, next_err
			}
			if !found {
				return {}, address_out_of_range(allocator)
			}
			start = after
		}
	}
	for remaining > 0 {
		after, found, err := find_next_lf(tree, start, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if !found {
			return {}, address_out_of_range(allocator)
		}
		start = after
		remaining -= 1
	}
	end, found, err := find_next_lf(tree, start, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	if !found {
		end = total
	}
	return rope.Byte_Range{start = start, end = end}, {}
}

backward_line :: proc(
	tree: ^rope.Tree,
	current: rope.Byte_Range,
	count: int,
	allocator: runtime.Allocator,
) -> (rope.Byte_Range, errs.Error) {
	if count == 0 {
		start, err := backward_line_start(tree, current.start, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		return rope.Byte_Range{start = start, end = current.start}, {}
	}
	position := current.start
	target_end := 0
	completed := 0
	for completed < count {
		if position == 0 {
			completed += 1
			if completed != count {
				return {}, address_out_of_range(allocator)
			}
			target_end = 0
			break
		}
		newline, found, err := find_previous_lf(tree, position, allocator)
		if !errs.ok(err) {
			return {}, err
		}
		if !found {
			position = 0
			continue
		}
		completed += 1
		if completed == count {
			target_end = newline + 1
			break
		}
		position = newline
	}
	start, err := backward_line_start(tree, target_end, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	return rope.Byte_Range{start = start, end = target_end}, {}
}

backward_line_start :: proc(tree: ^rope.Tree, end: int, allocator: runtime.Allocator) -> (int, errs.Error) {
	position := end
	if position > 0 {
		position -= 1
	}
	newline, found, err := find_previous_lf(tree, position, allocator)
	if !errs.ok(err) {
		return 0, err
	}
	if found {
		return newline + 1, {}
	}
	return 0, {}
}

byte_at :: proc(tree: ^rope.Tree, position: int, allocator: runtime.Allocator) -> (u8, errs.Error) {
	buffer: [1]u8
	n, err := rope.tree_read(tree, {start = position, end = position + 1}, buffer[:], allocator)
	if !errs.ok(err) {
		return 0, err
	}
	if n != 1 {
		return 0, errs.new(.Internal, "address: could not read a validated text byte", allocator = allocator)
	}
	return buffer[0], {}
}

find_next_lf :: proc(tree: ^rope.Tree, start: int, allocator: runtime.Allocator) -> (int, bool, errs.Error) {
	total := rope.tree_byte_count(tree)
	buffer: [LINE_SCAN_BYTES]u8
	for position := start; position < total; {
		end := min(total, position + len(buffer))
		n, err := rope.tree_read(tree, {start = position, end = end}, buffer[:end - position], allocator)
		if !errs.ok(err) {
			return 0, false, err
		}
		if n != end - position {
			return 0, false, errs.new(.Internal, "address: short line-scan read", allocator = allocator)
		}
		for index in 0 ..< n {
			if buffer[index] == '\n' {
				return position + index + 1, true, {}
			}
		}
		position = end
	}
	return total, false, {}
}

find_previous_lf :: proc(tree: ^rope.Tree, end: int, allocator: runtime.Allocator) -> (int, bool, errs.Error) {
	buffer: [LINE_SCAN_BYTES]u8
	position := end
	for position > 0 {
		start := max(0, position - len(buffer))
		n, err := rope.tree_read(tree, {start = start, end = position}, buffer[:position - start], allocator)
		if !errs.ok(err) {
			return 0, false, err
		}
		if n != position - start {
			return 0, false, errs.new(.Internal, "address: short reverse line-scan read", allocator = allocator)
		}
		for index := n - 1; index >= 0; index -= 1 {
			if buffer[index] == '\n' {
				return start + index, true, {}
			}
		}
		position = start
	}
	return 0, false, {}
}
