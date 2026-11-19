package address

import mem_virtual "core:mem/virtual"
import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"

MAX_REGEX_MATCHES :: 4096

// regex_find_matches returns successive non-overlapping matches in range. The
// caller owns the returned slice. At most max_matches are returned, allowing a
// caller that needs every match to request one extra as a budget check.
regex_find_matches :: proc(
	tree: ^rope.Tree,
	pattern: string,
	range: rope.Byte_Range,
	history: ^Regex_History,
	max_matches: int,
	allocator := context.allocator,
) -> ([]Regex_Match, errs.Error) {
	if tree == nil {
		return {}, errs.new(.Invalid_Input, "address: nil regular-expression tree", allocator = allocator)
	}
	total := rope.tree_byte_count(tree)
	if range.start < 0 || range.end < range.start || range.end > total {
		return {}, errs.new(.Invalid_Input, "address: match range is outside the document", allocator = allocator)
	}
	if max_matches <= 0 || max_matches > MAX_REGEX_MATCHES + 1 {
		return {}, errs.newf(.Resource_Limit, "address: match result budget is %d", MAX_REGEX_MATCHES, allocator = allocator)
	}
	pattern_text := pattern
	if len(pattern_text) == 0 {
		if history == nil || history.pattern_length <= 0 || history.pattern_length > len(history.pattern_bytes) {
			return {}, errs.new(.Invalid_Input, "address: empty regular expression has no previous pattern", allocator = allocator)
		}
		pattern_text = string(history.pattern_bytes[:history.pattern_length])
	}

	arena: mem_virtual.Arena
	if arena_err := mem_virtual.arena_init_growing(&arena); arena_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not initialize regular-expression scratch memory", allocator = allocator)
	}
	defer mem_virtual.arena_destroy(&arena)
	defer mem_virtual.arena_free_all(&arena)
	scratch := mem_virtual.arena_allocator(&arena)

	text_bytes, text_alloc_err := make([]u8, total, scratch)
	if text_alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate regular-expression text", allocator = allocator)
	}
	n, read_err := rope.tree_read(tree, {0, total}, text_bytes, allocator)
	if !errs.ok(read_err) {
		return {}, read_err
	}
	if n != total {
		return {}, errs.new(.Internal, "address: short regular-expression text read", allocator = allocator)
	}

	compiled, compile_err := compile_forward_regex(pattern_text, scratch, allocator, true)
	if !errs.ok(compile_err) {
		return {}, compile_err
	}
	matcher, matcher_err := regex_matcher_init(compiled, string(text_bytes), scratch, allocator, true)
	if !errs.ok(matcher_err) {
		return {}, matcher_err
	}
	if history != nil {
		copy(history.pattern_bytes[:], pattern_text)
		history.pattern_length = len(pattern_text)
	}

	matches, matches_err := make([]Regex_Match, max_matches, allocator)
	if matches_err != .None {
		return {}, errs.new(.Resource_Limit, "address: could not allocate regular-expression matches", allocator = allocator)
	}
	count := 0
	search_start := range.start
	previous_end := -1
	for search_start <= range.end && count < max_matches {
		match, found := regex_matcher_run_captures(&matcher, search_start, range.end + 1, range.end)
		if !matcher.valid {
			delete(matches, allocator)
			return {}, errs.new(.Internal, "address: invalid native regular-expression execution", allocator = allocator)
		}
		if !found {
			break
		}
		if match.range.start == match.range.end && match.range.start == previous_end {
			previous_end = match.range.end
			search_start = regex_next_position(string(text_bytes), match.range.end, range.end)
			continue
		}
		matches[count] = match
		count += 1
		previous_end = match.range.end
		if match.range.start == match.range.end {
			search_start = regex_next_position(string(text_bytes), match.range.end, range.end)
		} else {
			search_start = match.range.end
		}
	}
	return matches[:count], {}
}

regex_next_position :: proc(text: string, position: int, limit: int) -> int {
	if position >= limit {
		return limit + 1
	}
	_, width := utf8.decode_rune_in_string(text[position:])
	if width <= 0 {
		width = 1
	}
	next := position + width
	if next > limit {
		return limit + 1
	}
	return next
}
