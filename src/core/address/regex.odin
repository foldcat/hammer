package address

import "base:intrinsics"
import "base:runtime"
import mem_virtual "core:mem/virtual"
import "core:text/regex"
import regex_compiler "core:text/regex/compiler"
import regex_parser "core:text/regex/parser"
import regex_vm "core:text/regex/virtual_machine"
import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"

MAX_REGEX_GROUP_DEPTH :: 32
REGEX_SEARCH_WILDCARD_PC :: size_of(regex_vm.Split)
REGEX_BODY_PC :: size_of(regex_vm.Split) + 1 + size_of(regex_vm.Jump)

REGEX_CAPTURE_GROUPS :: 10

Regex_Match :: struct {
	range:  rope.Byte_Range,
	groups: [REGEX_CAPTURE_GROUPS]rope.Byte_Range,
}

Regex_Thread :: struct {
	pc:    int,
	start: int,
	saved: [2 * REGEX_CAPTURE_GROUPS]int,
}

Regex_Thread_List :: struct {
	threads: []Regex_Thread,
	busy:    []u64,
	count:   int,
}

Regex_Matcher :: struct {
	code:          regex_vm.Program,
	classes:       []regex_vm.Rune_Class_Data,
	text:          string,
	first:         Regex_Thread_List,
	second:        Regex_Thread_List,
	valid:         bool,
	with_captures: bool,
	cancelled:     ^bool,
}

regex_address :: proc(
	tree: ^rope.Tree,
	expression: ^Expression,
	operation: Operation,
	current: rope.Byte_Range,
	history: ^Regex_History,
	allocator: runtime.Allocator,
	cancelled: ^bool = nil,
) -> (rope.Byte_Range, errs.Error) {
	if err := check_cancellation(cancelled, allocator); !errs.ok(err) {
		return {}, err
	}
	if operation.direction != .Forward && operation.direction != .Backward {
		return {}, errs.new(.Invalid_Input, "address: invalid regular-expression direction", allocator = allocator)
	}
	if operation.pattern_offset < 0 || operation.pattern_length < 0 ||
		operation.pattern_offset > expression.pattern_bytes_used ||
		operation.pattern_length > expression.pattern_bytes_used - operation.pattern_offset ||
		expression.pattern_bytes_used > len(expression.pattern_bytes) {
		return {}, errs.new(.Invalid_Input, "address: invalid regular-expression span", allocator = allocator)
	}

	pattern := string(expression.pattern_bytes[operation.pattern_offset:operation.pattern_offset + operation.pattern_length])
	if len(pattern) == 0 {
		if history == nil || history.pattern_length <= 0 || history.pattern_length > len(history.pattern_bytes) {
			return {}, errs.new(.Invalid_Input, "address: empty regular expression has no previous pattern", allocator = allocator)
		}
		pattern = string(history.pattern_bytes[:history.pattern_length])
	}

	arena: mem_virtual.Arena
	if arena_err := mem_virtual.arena_init_growing(&arena); arena_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not initialize regular-expression scratch memory", allocator = allocator)
	}
	defer mem_virtual.arena_destroy(&arena)
	defer mem_virtual.arena_free_all(&arena)
	scratch := mem_virtual.arena_allocator(&arena)

	total := rope.tree_byte_count(tree)
	text_bytes, text_alloc_err := make([]u8, total, scratch)
	if text_alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate regular-expression text", allocator = allocator)
	}
	n, read_err := rope.tree_read(tree, {start = 0, end = total}, text_bytes, allocator)
	if !errs.ok(read_err) {
		return {}, read_err
	}
	if n != total {
		return {}, errs.new(.Internal, "address: short regular-expression text read", allocator = allocator)
	}

	normalized_bytes, normalized_alloc_err := make([]u8, 3 * len(pattern) + 16, scratch)
	if normalized_alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate normalized regular expression", allocator = allocator)
	}
	normalized_length, normalize_err := normalize_regex(pattern, normalized_bytes, allocator)
	if !errs.ok(normalize_err) {
		return {}, normalize_err
	}
	compiled: regex.Regular_Expression
	if operation.direction == .Backward {
		reversed, reversed_err := compile_reversed_regex(string(normalized_bytes[:normalized_length]), scratch, allocator)
		if !errs.ok(reversed_err) {
			return {}, reversed_err
		}
		compiled = reversed
	} else {
		forward, forward_err := regex.create(
			string(normalized_bytes[:normalized_length]),
			{.Unicode, .Multiline, .No_Capture, .No_Optimization},
			scratch,
			scratch,
		)
		if forward_err != nil {
			_, is_compiler_error := forward_err.(regex.Compiler_Error)
			if is_compiler_error {
				return {}, errs.new(.Resource_Limit, "address: regular expression exceeds the native engine capacity", allocator = allocator)
			}
			return {}, errs.new(.Invalid_Input, "address: malformed regular expression", allocator = allocator)
		}
		compiled = forward
	}
	if !valid_compiled_regex(compiled.program) {
		return {}, errs.new(.Internal, "address: unexpected native regular-expression program", allocator = allocator)
	}

	search_text := string(text_bytes)
	if operation.direction == .Backward {
		reversed_text, reverse_err := reverse_regex_text(text_bytes, scratch, allocator)
		if !errs.ok(reverse_err) {
			return {}, reverse_err
		}
		search_text = string(reversed_text)
	}
	matcher, matcher_err := regex_matcher_init(compiled, search_text, scratch, allocator, cancelled = cancelled)
	if !errs.ok(matcher_err) {
		return {}, matcher_err
	}

	use_end := operation.direction == .Forward
	if operation.origin == .Forward {
		use_end = true
	} else if operation.origin == .Backward {
		use_end = false
	}
	position := current.end if use_end else current.start
	if operation.direction == .Backward {
		position = total - position
	}

	match, found := regex_matcher_run(&matcher, position, total + 1)
	if err := check_cancellation(cancelled, allocator); !errs.ok(err) {
		return {}, err
	}
	if !matcher.valid {
		return {}, errs.new(.Internal, "address: invalid native regular-expression execution", allocator = allocator)
	}
	if !found && position > 0 {
		match, found = regex_matcher_run(&matcher, 0, total + 1)
	}
	if err := check_cancellation(cancelled, allocator); !errs.ok(err) {
		return {}, err
	}
	if !matcher.valid {
		return {}, errs.new(.Internal, "address: invalid native regular-expression execution", allocator = allocator)
	}
	if found && operation.direction == .Backward {
		match = {start = total - match.end, end = total - match.start}
	}

	if history != nil {
		copy(history.pattern_bytes[:], pattern)
		history.pattern_length = len(pattern)
	}
	if !found {
		return {}, errs.new(.NotFound, "address: regular expression did not match", allocator = allocator)
	}
	return match, {}
}

normalize_regex :: proc(pattern: string, out: []u8, allocator: runtime.Allocator, preserve_captures: bool = false) -> (int, errs.Error) {
	copy(out, "(?:^)?")
	n := 6
	in_class := false
	group_depth := 0
	for index := 0; index < len(pattern); {
		c := pattern[index]
		if c == 0 || c == '\n' {
			return 0, errs.new(.Invalid_Input, "address: invalid literal in regular expression", allocator = allocator)
		}
		if c == '\\' {
			if index + 1 >= len(pattern) || pattern[index + 1] == '\n' {
				return 0, errs.new(.Invalid_Input, "address: trailing or invalid regular-expression escape", allocator = allocator)
			}
			next := pattern[index + 1]
			keep_escape := next == 'n'
			if in_class {
				keep_escape = keep_escape || next == '-' || next == ']' || next == '^' || next == '\\'
			} else {
				switch next {
				case '.', '*', '+', '?', '[', ']', '(', ')', '|', '^', '$', '\\', '{', '}', '#':
					keep_escape = true
				}
			}
			if keep_escape {
				if n >= len(out) {
					return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
				}
				out[n] = '\\'
				n += 1
			}
			if n >= len(out) {
				return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
			}
			out[n] = next
			n += 1
			index += 2
			continue
		}
		if !in_class {
			if c == '(' {
				group_depth += 1
				if group_depth > MAX_REGEX_GROUP_DEPTH {
					return 0, errs.new(.Resource_Limit, "address: regular-expression groups are nested too deeply", allocator = allocator)
				}
				if preserve_captures {
					if n >= len(out) {
						return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
					}
					out[n] = '('
					n += 1
				} else {
					if n + 3 > len(out) {
						return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
					}
					copy(out[n:], "(?:")
					n += 3
				}
				index += 1
				continue
			}
			if c == ')' {
				group_depth -= 1
			}
			if c == '{' || c == '}' || c == '#' {
				if n >= len(out) {
					return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
				}
				out[n] = '\\'
				n += 1
			}
		}
		if c == '[' && !in_class {
			in_class = true
		} else if c == ']' && in_class {
			in_class = false
		}
		if n >= len(out) {
			return 0, errs.new(.Resource_Limit, "address: normalized regular expression is too large", allocator = allocator)
		}
		out[n] = c
		n += 1
		index += 1
	}
	if group_depth != 0 || in_class {
		return 0, errs.new(.Invalid_Input, "address: unclosed regular-expression group or character class", allocator = allocator)
	}
	return n, {}
}

compile_forward_regex :: proc(
	pattern: string,
	allocator: runtime.Allocator,
	error_allocator: runtime.Allocator,
	captures: bool,
) -> (regex.Regular_Expression, errs.Error) {
	normalized, alloc_err := make([]u8, 3 * len(pattern) + 16, allocator)
	if alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate normalized regular expression", allocator = error_allocator)
	}
	length, normalize_err := normalize_regex(pattern, normalized, error_allocator, captures)
	if !errs.ok(normalize_err) {
		return {}, normalize_err
	}
	flags := regex.Flags{.Unicode, .Multiline, .No_Optimization}
	if !captures {
		flags += {.No_Capture}
	}
	compiled, compile_err := regex.create(string(normalized[:length]), flags, allocator, allocator)
	if compile_err != nil {
		_, is_compiler_error := compile_err.(regex.Compiler_Error)
		if is_compiler_error {
			return {}, errs.new(.Resource_Limit, "address: regular expression exceeds the native engine capacity", allocator = error_allocator)
		}
		return {}, errs.new(.Invalid_Input, "address: malformed regular expression", allocator = error_allocator)
	}
	if !valid_compiled_regex(compiled.program) {
		return {}, errs.new(.Internal, "address: unexpected native regular-expression program", allocator = error_allocator)
	}
	return compiled, {}
}

compile_reversed_regex :: proc(
	pattern: string,
	allocator: runtime.Allocator,
	error_allocator: runtime.Allocator,
) -> (regex.Regular_Expression, errs.Error) {
	flags := regex.Flags{.Unicode, .Multiline, .No_Capture, .No_Optimization}
	ast: regex_parser.Node
	parse_err: regex_parser.Error
	{
		context.allocator = allocator
		ast, parse_err = regex_parser.parse(pattern, flags)
	}
	if parse_err != nil {
		return {}, errs.new(.Invalid_Input, "address: malformed regular expression", allocator = error_allocator)
	}
	reverse_regex_ast(ast)

	{
		context.allocator = allocator
		anchor := new(regex_parser.Node_Anchor)
		anchor.start = true
		optional := new(regex_parser.Node_Optional)
		optional.inner = anchor
		group := new(regex_parser.Node_Group)
		group.inner = optional
		concatenation := new(regex_parser.Node_Concatenation)
		append(&concatenation.nodes, group)
		append(&concatenation.nodes, ast)
		ast = concatenation
	}

	program: regex_compiler.Program
	classes: [dynamic]regex_parser.Rune_Class_Data
	compiler_err: regex_compiler.Error
	{
		context.allocator = allocator
		program, classes, compiler_err = regex_compiler.compile(ast, flags)
	}
	if compiler_err != .None {
		return {}, errs.new(.Resource_Limit, "address: regular expression exceeds the native engine capacity", allocator = error_allocator)
	}
	converted, convert_err := make([]regex_vm.Rune_Class_Data, len(classes), allocator)
	if convert_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate regular-expression classes", allocator = error_allocator)
	}
	for data, index in classes {
		converted[index] = {runes = data.runes[:], ranges = data.ranges[:]}
	}
	return {flags = flags, program = program[:], class_data = converted}, {}
}

reverse_regex_ast :: proc(node: regex_parser.Node) {
	if node == nil {
		return
	}
	switch specific in node {
	case ^regex_parser.Node_Rune, ^regex_parser.Node_Rune_Class, ^regex_parser.Node_Wildcard,
		^regex_parser.Node_Word_Boundary, ^regex_parser.Node_Match_All_And_Escape:
		return
	case ^regex_parser.Node_Concatenation:
		for child in specific.nodes {
			reverse_regex_ast(child)
		}
		left := 0
		right := len(specific.nodes) - 1
		for left < right {
			specific.nodes[left], specific.nodes[right] = specific.nodes[right], specific.nodes[left]
			left += 1
			right -= 1
		}
	case ^regex_parser.Node_Alternation:
		reverse_regex_ast(specific.left)
		reverse_regex_ast(specific.right)
	case ^regex_parser.Node_Repeat_Zero:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Repeat_Zero_Non_Greedy:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Repeat_One:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Repeat_One_Non_Greedy:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Repeat_N:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Optional:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Optional_Non_Greedy:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Group:
		reverse_regex_ast(specific.inner)
	case ^regex_parser.Node_Anchor:
		specific.start = !specific.start
	}
}

reverse_regex_text :: proc(text: []u8, allocator: runtime.Allocator, error_allocator: runtime.Allocator) -> ([]u8, errs.Error) {
	reversed, alloc_err := make([]u8, len(text), allocator)
	if alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate reverse regular-expression text", allocator = error_allocator)
	}
	source := 0
	destination := len(text)
	for source < len(text) {
		_, size := utf8.decode_rune_in_string(string(text[source:]))
		if size <= 0 {
			return {}, errs.new(.Invalid_Input, "address: invalid UTF-8 in regular-expression text", allocator = error_allocator)
		}
		destination -= size
		copy(reversed[destination:destination + size], text[source:source + size])
		source += size
	}
	return reversed, {}
}

valid_compiled_regex :: proc(code: regex_vm.Program) -> bool {
	if len(code) <= REGEX_BODY_PC || code[0] != .Split || code[REGEX_SEARCH_WILDCARD_PC] != .Wildcard ||
		code[REGEX_SEARCH_WILDCARD_PC + 1] != .Jump {
		return false
	}
	return regex_code_u16(code, 1) == REGEX_BODY_PC && regex_code_u16(code, 3) == REGEX_SEARCH_WILDCARD_PC
}

regex_matcher_init :: proc(
	compiled: regex.Regular_Expression,
	text: string,
	allocator: runtime.Allocator,
	error_allocator: runtime.Allocator,
	captures: bool = false,
	cancelled: ^bool = nil,
) -> (Regex_Matcher, errs.Error) {
	matcher := Regex_Matcher{
		code = compiled.program,
		classes = compiled.class_data,
		text = text,
		valid = true,
		with_captures = captures,
		cancelled = cancelled,
	}
	thread_capacity := len(compiled.program) + 1
	busy_capacity := (len(compiled.program) + 63) / 64
	first_threads, first_err := make([]Regex_Thread, thread_capacity, allocator)
	second_threads, second_err := make([]Regex_Thread, thread_capacity, allocator)
	first_busy, first_busy_err := make([]u64, busy_capacity, allocator)
	second_busy, second_busy_err := make([]u64, busy_capacity, allocator)
	if first_err != .None || second_err != .None || first_busy_err != .None || second_busy_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate native regular-expression threads", allocator = error_allocator)
	}
	matcher.first = {threads = first_threads, busy = first_busy}
	matcher.second = {threads = second_threads, busy = second_busy}
	return matcher, {}
}

regex_matcher_run :: proc(matcher: ^Regex_Matcher, min_start: int, max_start: int, limit: int = -1) -> (rope.Byte_Range, bool) {
	match, found := regex_matcher_run_captures(matcher, min_start, max_start, limit)
	return match.range, found
}

regex_matcher_run_captures :: proc(matcher: ^Regex_Matcher, min_start: int, max_start: int, limit_value: int) -> (Regex_Match, bool) {
	matcher.valid = true
	if cancellation_requested(matcher.cancelled) {
		return {}, false
	}
	limit := limit_value
	if limit < 0 || limit > len(matcher.text) {
		limit = len(matcher.text)
	}
	current := &matcher.first
	next := &matcher.second
	regex_clear_thread_list(current)
	regex_clear_thread_list(next)
	current_rune, current_size := regex_rune_at(matcher.text, 0)
	regex_add_thread(matcher, current, regex_new_thread(0, -1), 0, 0, current_rune, min_start, max_start)

	position := 0
	best := Regex_Match{range = {start = -1, end = -1}}
	for &group in best.groups {
		group = {start = -1, end = -1}
	}
	found := false
	for current.count > 0 {
		if cancellation_requested(matcher.cancelled) {
			return {}, false
		}
		next.count = 0
		regex_zero_busy(next.busy)
		next_position := position + current_size
		next_rune, _ := regex_rune_at(matcher.text, next_position)
		for index in 0 ..< current.count {
			if index & 63 == 0 && cancellation_requested(matcher.cancelled) {
				return {}, false
			}
			thread := current.threads[index]
			if thread.pc < 0 || thread.pc >= len(matcher.code) {
				matcher.valid = false
				return {}, false
			}
			opcode := matcher.code[thread.pc]
			switch opcode {
			case .Match, .Match_And_Exit:
				if thread.start < 0 {
					matcher.valid = false
					return {}, false
				}
				if !found || thread.start < best.range.start || (thread.start == best.range.start && position > best.range.end) {
					best.range = {start = thread.start, end = position}
					best.groups[0] = best.range
					if matcher.with_captures {
						for group_index in 1 ..< REGEX_CAPTURE_GROUPS {
							start := thread.saved[2 * group_index]
							end := thread.saved[2 * group_index + 1]
							if start >= 0 && end >= start {
								best.groups[group_index] = {start = start, end = end}
							} else {
								best.groups[group_index] = {start = -1, end = -1}
							}
						}
					}
					found = true
				}
			case .Byte:
				if next_position <= limit && current_size > 0 && current_rune == rune(matcher.code[thread.pc + 1]) {
					regex_add_thread(matcher, next, {pc = thread.pc + 2, start = thread.start, saved = thread.saved}, next_position, current_rune, next_rune, min_start, max_start)
				}
			case .Rune:
				operand := intrinsics.unaligned_load(cast(^rune)&matcher.code[thread.pc + 1])
				if next_position <= limit && current_size > 0 && current_rune == operand {
					regex_add_thread(matcher, next, {pc = thread.pc + 1 + size_of(rune), start = thread.start, saved = thread.saved}, next_position, current_rune, next_rune, min_start, max_start)
				}
			case .Rune_Class, .Rune_Class_Negated:
				class_index := int(matcher.code[thread.pc + 1])
				if class_index < 0 || class_index >= len(matcher.classes) {
					matcher.valid = false
					return {}, false
				}
				matched := regex_class_matches(matcher.classes[class_index], current_rune)
				if opcode == .Rune_Class_Negated {
					matched = !matched && current_rune != '\n'
				}
				if next_position <= limit && current_size > 0 && matched {
					regex_add_thread(matcher, next, {pc = thread.pc + 2, start = thread.start, saved = thread.saved}, next_position, current_rune, next_rune, min_start, max_start)
				}
			case .Wildcard:
				if next_position <= limit && current_size > 0 && (thread.pc == REGEX_SEARCH_WILDCARD_PC || current_rune != '\n') {
					regex_add_thread(matcher, next, {pc = thread.pc + 1, start = thread.start, saved = thread.saved}, next_position, current_rune, next_rune, min_start, max_start)
				}
			case .Jump, .Split, .Save, .Assert_Start, .Assert_Start_Multiline, .Assert_End,
				.Assert_Word_Boundary, .Assert_Non_Word_Boundary, .Multiline_Open, .Multiline_Close,
				.Wait_For_Byte, .Wait_For_Rune, .Wait_For_Rune_Class, .Wait_For_Rune_Class_Negated,
				.Match_All_And_Escape:
				matcher.valid = false
				return {}, false
			}
		}
		if next.count == 0 || current_size == 0 || position >= limit {
			break
		}
		position = next_position
		current_rune = next_rune
		_, current_size = regex_rune_at(matcher.text, position)
		current, next = next, current
	}
	return best, found
}

regex_new_thread :: proc(pc, start: int) -> Regex_Thread {
	thread := Regex_Thread{pc = pc, start = start}
	for &saved in thread.saved {
		saved = -1
	}
	return thread
}

regex_add_thread :: proc(
	matcher: ^Regex_Matcher,
	list: ^Regex_Thread_List,
	thread: Regex_Thread,
	position: int,
	previous_rune: rune,
	current_rune: rune,
	min_start: int,
	max_start: int,
) {
	pc := thread.pc
	start := thread.start
	saved := thread.saved
	for {
		if pc == REGEX_BODY_PC && start < 0 {
			start = position
			if start < min_start || start >= max_start {
				return
			}
		}
		if pc < 0 || pc >= len(matcher.code) {
			matcher.valid = false
			return
		}
		slot := pc >> 6
		bit := u64(1) << (u64(pc) & 63)
		if list.busy[slot] & bit != 0 {
			return
		}
		list.busy[slot] |= bit

		opcode := matcher.code[pc]
		#partial switch opcode {
		case .Jump:
			pc = regex_code_u16(matcher.code, pc + 1)
		case .Split:
			left := regex_code_u16(matcher.code, pc + 1)
			right := regex_code_u16(matcher.code, pc + 3)
			regex_add_thread(matcher, list, {pc = left, start = start, saved = saved}, position, previous_rune, current_rune, min_start, max_start)
			pc = right
		case .Save:
			if matcher.with_captures {
				index := int(matcher.code[pc + 1])
				if index < 0 || index >= len(saved) {
					matcher.valid = false
					return
				}
				saved[index] = position
			}
			pc += 2
		case .Assert_Start:
			if position != 0 {
				return
			}
			pc += 1
		case .Assert_Start_Multiline:
			if position != 0 && previous_rune != '\n' {
				return
			}
			pc += 1
		case .Assert_End:
			if position != len(matcher.text) {
				return
			}
			pc += 1
		case .Multiline_Open:
			if position != len(matcher.text) && current_rune != '\n' {
				return
			}
			pc += 2
		case .Multiline_Close:
			matcher.valid = false
			return
		case:
			if list.count >= len(list.threads) {
				matcher.valid = false
				return
			}
			list.threads[list.count] = {pc = pc, start = start, saved = saved}
			list.count += 1
			return
		}
	}
}

regex_clear_thread_list :: proc(list: ^Regex_Thread_List) {
	list.count = 0
	regex_zero_busy(list.busy)
}

regex_zero_busy :: proc(busy: []u64) {
	for &word in busy {
		word = 0
	}
}

regex_rune_at :: proc(text: string, position: int) -> (rune, int) {
	if position >= len(text) {
		return 0, 0
	}
	return utf8.decode_rune_in_string(text[position:])
}

regex_code_u16 :: proc(code: regex_vm.Program, offset: int) -> int {
	return int(code[offset]) | int(code[offset + 1]) << 8
}

regex_class_matches :: proc(class: regex_vm.Rune_Class_Data, r: rune) -> bool {
	for candidate in class.runes {
		if candidate == r {
			return true
		}
	}
	for range in class.ranges {
		if range.lower <= r && r <= range.upper {
			return true
		}
	}
	return false
}
