package shaping

import "core:unicode/utf8"

import errs "../../core/errs"

DEFAULT_TAB_WIDTH :: 4
MAX_TAB_WIDTH :: 32

Expanded_Tab :: struct {
	source_offset:  int,
	display_offset: int,
	spaces:         int,
}

// Tab_Expansion owns text and tabs. Source offsets refer to the original line;
// text and display offsets refer to its space-expanded representation.
Tab_Expansion :: struct {
	text:          [dynamic]u8,
	tabs:          [dynamic]Expanded_Tab,
	source_length: int,
}

expand_tabs :: proc(line: string, width := DEFAULT_TAB_WIDTH, allocator := context.allocator) -> (Tab_Expansion, errs.Error) {
	if width <= 0 || width > MAX_TAB_WIDTH {
		return {}, errs.new(.Invalid_Input, "shaping: invalid tab width", allocator = allocator)
	}
	if !utf8.valid_string(line) {
		return {}, errs.new(.Invalid_Input, "shaping: tab expansion requires valid UTF-8", allocator = allocator)
	}
	result := Tab_Expansion{
		text = make([dynamic]u8, 0, len(line), allocator),
		tabs = make([dynamic]Expanded_Tab, allocator),
		source_length = len(line),
	}
	column := 0
	iterator := utf8.decode_grapheme_iterator_make(line)
	for text, grapheme in utf8.decode_grapheme_iterate(&iterator) {
		if text == "\t" {
			spaces := width - column % width
			append(&result.tabs, Expanded_Tab{
				source_offset = grapheme.byte_index,
				display_offset = len(result.text),
				spaces = spaces,
			})
			for _ in 0 ..< spaces {
				append(&result.text, ' ')
			}
			column += spaces
			continue
		}
		for index in 0 ..< len(text) {
			append(&result.text, text[index])
		}
		column += 1
	}
	return result, {}
}

tab_expansion_destroy :: proc(expansion: ^Tab_Expansion) {
	delete(expansion.text)
	delete(expansion.tabs)
	expansion^ = Tab_Expansion{}
}

tab_display_offset :: proc(expansion: Tab_Expansion, source_offset: int) -> (int, bool) {
	if source_offset < 0 || source_offset > expansion.source_length {
		return 0, false
	}
	display_offset := source_offset
	for tab in expansion.tabs {
		if source_offset <= tab.source_offset {
			break
		}
		display_offset += tab.spaces - 1
	}
	return display_offset, true
}

// tab_source_offset maps a display caret back to its source caret. A hit inside
// an expanded tab chooses the nearer source edge, with ties choosing the end.
tab_source_offset :: proc(expansion: Tab_Expansion, display_offset: int) -> (int, bool) {
	if display_offset < 0 || display_offset > len(expansion.text) {
		return 0, false
	}
	source_offset := display_offset
	for tab in expansion.tabs {
		if display_offset < tab.display_offset {
			break
		}
		if display_offset <= tab.display_offset + tab.spaces {
			relative := display_offset - tab.display_offset
			if relative < (tab.spaces + 1) / 2 {
				return tab.source_offset, true
			}
			return tab.source_offset + 1, true
		}
		source_offset -= tab.spaces - 1
	}
	return source_offset, true
}
