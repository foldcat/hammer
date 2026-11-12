// A deliberately minimal YAML subset parser for the config file.
//
// Supported (and that is all the config schema needs):
//   - flat and one-level nested block mappings (`theme:` under a top
//     level), 2-space indentation;
//   - plain scalars and single-/double-quoted scalars;
//   - block sequences of scalars (`- item` lines) and inline sequences
//     (`[a, b]`);
//   - full-line comments (a line whose first non-blank character is #);
//   - blank lines.
//
// Rejected with an error: tabs, anchors/aliases, flow mappings,
// multi-line scalars, deeper nesting, and any structural syntax that
// does not fit the subset. Being strict is deliberate: a config file
// using an unsupported construct must fail the build loudly instead of
// being misread.
//
// Ownership: `parse_document` returns a Document that owns its maps and
// slices; destroy it with `document_destroy`. Scalar strings inside it
// borrow from the caller-provided input text, which must outlive the
// Document. All temporary allocation uses `context.allocator`.
package config

import "base:runtime"
import "core:strconv"
import "core:strings"

import errs "../errs"

// value_kind distinguishes how a scalar was written, which controls
// coercion: a quoted scalar is always a string, never a number or bool.
value_kind :: enum {
	String,
	Number,
	Bool,
}

value :: struct {
	text: string, // stored form: unquoted content, or the raw literal
	kind: value_kind,
	// owned is set when `text` was allocated during unescaping (the
	// single-quoted `''` -> `'` case); `document_destroy` frees it with
	// context.allocator. Unescaped strings borrow from the input text.
	owned: bool,
}

// map_node is a parsed mapping: keys to values plus the source line of
// each entry (1-based, for error messages).
map_node :: struct {
	entries: map[string]value_node,
	lines:   map[string]int,
}

value_node :: union {
	^map_node,
	value,
	[]value,
}

document :: struct {
	root: map_node,
}

// document_destroy releases a parsed document and everything it owns
// (maps, slices, and any unescaping allocations). `allocator` must
// match the one passed to `parse_document`. Safe on a zero Document.
document_destroy :: proc(doc: ^document, allocator := context.allocator) {
	for _, entry in doc.root.entries {
		#partial switch node in entry {
		case ^map_node:
			child := node
			for _, child_entry in child.entries {
				#partial switch child_node in child_entry {
				case value:
					if child_node.owned {
						delete(child_node.text, allocator)
					}
				}
			}
			delete(child.entries)
			delete(child.lines)
			free(child, allocator)
		case value:
			if node.owned {
				delete(node.text, allocator)
			}
		case []value:
			delete(node, allocator)
		}
	}
	delete(doc.root.entries)
	delete(doc.root.lines)
	doc^ = document{}
}

// parse_document parses `text` into a Document. All values are owned by
// the returned Document; scalar strings borrow from `text`.
parse_document :: proc(text: string, allocator := context.allocator) -> (document, errs.Error) {
	if tab_err := check_no_tabs(text); !errs.ok(tab_err) {
		return document{}, tab_err
	}
	lines := strings.split_lines(text, allocator)
	defer delete(lines, allocator)

	doc := document{root = map_node{
		entries = make(map[string]value_node, 8, allocator),
		lines = make(map[string]int, 8, allocator),
	}}
	if consumed, ok := parse_map(&doc.root, lines, 0, 0, allocator); !ok {
		document_destroy(&doc, allocator)
		return document{}, errs.new(
			.Invalid_Input,
			"config: invalid YAML structure (unsupported nesting, indentation, or value form)",
		)
	} else if next_content_line(lines, consumed) != len(lines) {
		// Content remains that a mapping could not consume (e.g. a bare
		// top-level list or a key without a value).
		document_destroy(&doc, allocator)
		return document{}, errs.new(
			.Invalid_Input,
			"config: unexpected content after the top-level mapping",
		)
	}
	return doc, errs.Error{}
}

// parse_map parses mapping entries at indentation `indent` starting at
// `line` (0-based). It stops at the first content line with a smaller
// indent. Returns the next unconsumed line and success.
parse_map :: proc(
	node: ^map_node,
	lines: []string,
	line, indent: int,
	allocator: runtime.Allocator,
) -> (int, bool) {
	i := line
	for i < len(lines) {
		raw := lines[i]
		if is_blank_or_comment(raw) {
			i += 1
			continue
		}
		ind := indent_of(raw)
		if ind < indent {
			return i, true // end of this mapping
		}
		if ind != indent {
			return i, false
		}
		trimmed := raw[ind:]
		key, has_key := parse_key(trimmed)
		if !has_key {
			return i, false
		}
		colon := key_end(trimmed)
		rest := strings.trim_left_space(trimmed[colon + 1:])
		if rest != "" {
			node.entries[key] = parse_value(rest, allocator)
			node.lines[key] = i + 1
			i += 1
			continue
		}
		// Value on following lines: a nested mapping or a block sequence.
		next := next_content_line(lines, i + 1)
		if next == len(lines) {
			return i, false // key with no value
		}
		next_ind := indent_of(lines[next])
		if next_ind <= indent {
			return i, false // no deeper content
		}
		if is_list_item(lines[next]) {
			list := make([dynamic]value, allocator)
			consumed, ok := parse_list(&list, lines, i + 1, next_ind, allocator)
			if !ok {
				delete(list)
				return i, false
			}
			i = consumed
			node.entries[key] = list[:]
			node.lines[key] = next + 1
		} else {
			child := new(map_node, allocator)
			child.entries = make(map[string]value_node, 4, allocator)
			child.lines = make(map[string]int, 4, allocator)
			consumed, ok := parse_map(child, lines, i + 1, next_ind, allocator)
			if !ok {
				delete(child.entries)
				delete(child.lines)
				free(child)
				return i, false
			}
			i = consumed
			node.entries[key] = child
			node.lines[key] = next + 1
		}
	}
	return i, true
}

// parse_list parses `- item` lines at indentation `indent` starting at
// `line` (0-based). It stops at the first content line with a smaller
// indent. Returns the next unconsumed line and success.
parse_list :: proc(list: ^[dynamic]value, lines: []string, line, indent: int, allocator: runtime.Allocator) -> (int, bool) {
	i := line
	for i < len(lines) {
		raw := lines[i]
		if is_blank_or_comment(raw) {
			i += 1
			continue
		}
		ind := indent_of(raw)
		if ind < indent {
			return i, true
		}
		if ind != indent || !is_list_item(raw) {
			return i, false
		}
		item := strings.trim_left_space(raw[ind + 1:]) // past the "-"
		append(list, parse_scalar(item, allocator))
		i += 1
	}
	return i, true
}

// parse_value converts a same-line value (already trimmed of leading
// whitespace) into a value_node: a scalar, or an inline [..] list.
// Temporary strings it allocates are freed with `allocator`.
parse_value :: proc(text: string, allocator: runtime.Allocator) -> value_node {
	if strings.has_prefix(text, "[") && strings.has_suffix(text, "]") {
		inner := strings.trim_space(text[1:len(text) - 1])
		if inner == "" {
			return value_node([]value{})
		}
		parts, split_err := strings.split(inner, ",", allocator)
		if split_err != nil {
			return value_node([]value{})
		}
		defer delete(parts, allocator)
		list := make([]value, len(parts), allocator)
		for part, i in parts {
			list[i] = parse_scalar(strings.trim_space(part), allocator)
		}
		return value_node(list[:])
	}
	return value_node(parse_scalar(text, allocator))
}

// parse_scalar converts a scalar's stored form into a value. Unescape
// allocations (the single-quoted '' -> ' case) use `allocator` and are
// marked `owned`; `document_destroy` frees them with the same
// allocator.
parse_scalar :: proc(text: string, allocator: runtime.Allocator) -> value {
	if strings.has_prefix(text, "\"") && len(text) >= 2 && strings.has_suffix(text, "\"") {
		return value{text = text[1:len(text) - 1], kind = .String}
	}
	if strings.has_prefix(text, "'") && len(text) >= 2 && strings.has_suffix(text, "'") {
		// Single-quoted YAML: '' is an escaped quote; no other escapes.
		body := text[1:len(text) - 1]
		if strings.contains(body, "''") {
			unescaped, _ := strings.replace_all(body, "''", "'", allocator)
			return value{text = unescaped, kind = .String, owned = true}
		}
		return value{text = body, kind = .String}
	}
	_, number_ok := strconv.parse_f64(text)
	if number_ok {
		return value{text = text, kind = .Number}
	}
	// YAML boolean literals; the comparison is allocation-free.
	switch text {
	case "true", "True", "TRUE", "false", "False", "FALSE":
		return value{text = text, kind = .Bool}
	}
	return value{text = text, kind = .String}
}

// parse_key extracts the key part of a mapping line (the text before
// the first unquoted ':'), trimming trailing whitespace.
parse_key :: proc(line: string) -> (string, bool) {
	colon := key_end(line)
	if colon <= 0 {
		return "", false
	}
	return strings.trim_right_space(line[:colon]), true
}

// key_end returns the offset of the first unquoted ':' in `line`, or
// -1 when there is none.
key_end :: proc(line: string) -> int {
	in_single := false
	in_double := false
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		switch {
		case c == '\'' && !in_double:
			in_single = !in_single
		case c == '"' && !in_single:
			in_double = !in_double
		case c == ':' && !in_single && !in_double:
			return i
		}
	}
	return -1
}

// indent_of returns the leading-space count of a line.
indent_of :: proc(line: string) -> int {
	count := 0
	for count < len(line) && line[count] == ' ' {
		count += 1
	}
	return count
}

is_blank_or_comment :: proc(line: string) -> bool {
	trimmed := strings.trim_left_space(line)
	return len(trimmed) == 0 || trimmed[0] == '#'
}

is_list_item :: proc(line: string) -> bool {
	ind := indent_of(line)
	return ind < len(line) && line[ind] == '-' &&
		(ind + 1 >= len(line) || line[ind + 1] == ' ')
}

next_content_line :: proc(lines: []string, from: int) -> int {
	for i := from; i < len(lines); i += 1 {
		if !is_blank_or_comment(lines[i]) {
			return i
		}
	}
	return len(lines)
}

// check_no_tabs rejects tab-indented input up front. A tab inside a
// quoted scalar is fine; tabs outside quotes (indentation or plain
// scalars) are not.
check_no_tabs :: proc(text: string) -> errs.Error {
	in_single := false
	in_double := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		switch {
		case c == '\'' && !in_double:
			in_single = !in_single
		case c == '"' && !in_single:
			in_double = !in_double
		case c == '\t' && !in_single && !in_double:
			return errs.newf(
				.Invalid_Input,
				"config: tab character at byte %d; use spaces for indentation",
				i,
			)
		}
	}
	return errs.Error{}
}
