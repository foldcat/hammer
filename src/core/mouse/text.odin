package mouse

import "core:unicode"
import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"
import txn "../txn"

MAX_ACTION_TEXT_BYTES :: 64 * 1024
MAX_TOKEN_SCAN_BYTES :: 64 * 1024

Token_Kind :: enum u8 {
	Execute,
	Look,
	Word,
}

validate_range :: proc(doc: ^txn.Doc, range: rope.Byte_Range, allocator := context.allocator) -> errs.Error {
	if doc == nil {
		return errs.new(.Invalid_Input, "mouse: nil text document", allocator = allocator)
	}
	total := rope.tree_byte_count(&doc.tree)
	if range.start < 0 || range.end < range.start || range.end > total {
		return errs.newf(.Invalid_Input, "mouse: range [%d, %d) outside [0, %d]", range.start, range.end, total, allocator = allocator)
	}
	if range.end - range.start > MAX_ACTION_TEXT_BYTES {
		return errs.newf(.Resource_Limit, "mouse: text exceeds the %d-byte action budget", MAX_ACTION_TEXT_BYTES, allocator = allocator)
	}
	return {}
}

read_action_text :: proc(doc: ^txn.Doc, range: rope.Byte_Range, allocator := context.allocator) -> ([]byte, errs.Error) {
	if err := validate_range(doc, range, allocator); !errs.ok(err) {
		return {}, err
	}
	data, err := rope.tree_read_all(&doc.tree, range, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	if !utf8.valid_string(string(data)) {
		delete(data, allocator)
		return {}, errs.new(.Invalid_Input, "mouse: action text is not valid UTF-8", allocator = allocator)
	}
	return data, {}
}

action_range :: proc(
	doc: ^txn.Doc,
	selection: txn.Selection,
	anchor: int,
	active: int,
	kind: Token_Kind,
	allocator := context.allocator,
) -> (rope.Byte_Range, errs.Error) {
	if doc == nil {
		return {}, errs.new(.Invalid_Input, "mouse: nil text document", allocator = allocator)
	}
	total := rope.tree_byte_count(&doc.tree)
	if anchor < 0 || anchor > total || active < 0 || active > total || !txn.selection_in_bounds(selection, total) {
		return {}, errs.new(.Invalid_Input, "mouse: action offset is outside the document", allocator = allocator)
	}
	if anchor != active {
		range := rope.Byte_Range{min(anchor, active), max(anchor, active)}
		return range, validate_range(doc, range, allocator)
	}
	selected := rope.Byte_Range{min(selection.anchor, selection.active), max(selection.anchor, selection.active)}
	if selected.start != selected.end && anchor >= selected.start && anchor <= selected.end {
		return selected, validate_range(doc, selected, allocator)
	}
	return expand_token(doc, anchor, kind, allocator)
}

is_token :: proc(r: rune, kind: Token_Kind) -> bool {
	if kind == .Word {
		return unicode.is_letter(r) || unicode.is_number(r)
	}
	if unicode.is_letter(r) || unicode.is_number(r) {
		return true
	}
	switch r {
	case '_', '.', '-', '+', '/', '@':
		return true
	case ':':
		return kind == .Look
	case '\\':
		return kind == .Look
	case '<', '|', '>':
		return kind == .Execute
	}
	return false
}

expand_token :: proc(doc: ^txn.Doc, offset: int, kind: Token_Kind, allocator := context.allocator) -> (rope.Byte_Range, errs.Error) {
	data, base, window_end, err := read_scan_window(doc, offset, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	defer delete(data, allocator)
	click := offset - base
	start := click
	in_token := false
	for cursor := 0; cursor < click; {
		r, width := utf8.decode_rune_in_string(string(data[cursor:]))
		if width <= 0 || cursor + width > click {
			r = utf8.RUNE_ERROR
			width = 1
		}
		if is_token(r, kind) {
			if !in_token {
				start = cursor
				in_token = true
			}
		} else {
			in_token = false
			start = cursor + width
		}
		cursor += width
	}
	end := click
	for end < len(data) {
		r, width := utf8.decode_rune_in_string(string(data[end:]))
		if width <= 0 || !is_token(r, kind) {
			break
		}
		end += width
	}
	if !in_token && end == click {
		return {offset, offset}, {}
	}
	if end - start > MAX_ACTION_TEXT_BYTES ||
		(start == 0 && base > 0 && in_token) ||
		(end == len(data) && window_end < rope.tree_byte_count(&doc.tree) && end > click) {
		return {}, errs.newf(.Resource_Limit, "mouse: token exceeds the action or scan budget", allocator = allocator)
	}
	return {base + start, base + end}, {}
}

double_click_range :: proc(doc: ^txn.Doc, offset: int, allocator := context.allocator) -> (rope.Byte_Range, errs.Error) {
	if doc == nil || offset < 0 || offset > rope.tree_byte_count(&doc.tree) {
		return {}, errs.new(.Invalid_Input, "mouse: double-click offset is outside the document", allocator = allocator)
	}
	data, base, window_end, err := read_scan_window(doc, offset, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	defer delete(data, allocator)
	click := offset - base
	if click > 0 {
		if open, close, ok := opener_pair(data[click - 1]); ok {
			depth := 1
			for index := click; index < len(data); index += 1 {
				if data[index] == close {
					depth -= 1
					if depth == 0 {
						return {offset, base + index}, {}
					}
				} else if data[index] == open {
					depth += 1
				}
			}
		}
	}
	if click < len(data) {
		if open, close, ok := closer_pair(data[click]); ok {
			depth := 1
			for index := click - 1; index >= 0; index -= 1 {
				if data[index] == close {
					depth += 1
				} else if data[index] == open {
					depth -= 1
					if depth == 0 {
						return {base + index + 1, offset}, {}
					}
				}
			}
		}
	}
	if (click > 0 && data[click - 1] == '\n') || (click < len(data) && data[click] == '\n') {
		start := click
		for start > 0 && data[start - 1] != '\n' {
			start -= 1
		}
		end := click
		for end < len(data) && data[end] != '\n' {
			end += 1
		}
		if (start == 0 && base > 0) || (end == len(data) && window_end < rope.tree_byte_count(&doc.tree)) {
			return {}, errs.new(.Resource_Limit, "mouse: line exceeds the double-click scan budget", allocator = allocator)
		}
		if end > start && data[end - 1] == '\r' {
			end -= 1
		}
		return {base + start, base + end}, {}
	}
	return expand_token(doc, offset, .Word, allocator)
}

opener_pair :: proc(b: u8) -> (u8, u8, bool) {
	switch b {
	case '(':
		return '(', ')', true
	case '[', '{', '<':
		return b, b + 2, true
	case '\'', '"', '`':
		return b, b, true
	}
	return 0, 0, false
}

closer_pair :: proc(b: u8) -> (u8, u8, bool) {
	switch b {
	case ')', ']', '}':
		return b - 1, b, true
	case '>':
		return '<', '>', true
	case '\'', '"', '`':
		return b, b, true
	}
	return 0, 0, false
}

read_scan_window :: proc(doc: ^txn.Doc, offset: int, allocator := context.allocator) -> ([]byte, int, int, errs.Error) {
	if doc == nil {
		return {}, 0, 0, errs.new(.Invalid_Input, "mouse: nil text document", allocator = allocator)
	}
	total := rope.tree_byte_count(&doc.tree)
	if offset < 0 || offset > total {
		return {}, 0, 0, errs.new(.Invalid_Input, "mouse: scan offset is outside the document", allocator = allocator)
	}
	start := 0
	if offset > MAX_TOKEN_SCAN_BYTES {
		start = offset - MAX_TOKEN_SCAN_BYTES
	}
	end := total
	if total - offset > MAX_TOKEN_SCAN_BYTES {
		end = offset + MAX_TOKEN_SCAN_BYTES
	}
	data, err := rope.tree_read_all(&doc.tree, {start, end}, allocator)
	return data, start, end, err
}
