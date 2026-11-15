package textdeps_test

import "core:testing"

import shaping "hammer:text/shaping"

@(test)
test_tab_expansion_uses_grapheme_tab_stops_and_preserves_offsets :: proc(t: ^testing.T) {
	expansion, err := shaping.expand_tabs("a\tb\t中")
	if !expect_font_ok(t, err) {
		return
	}
	defer shaping.tab_expansion_destroy(&expansion)
	testing.expectf(t, string(expansion.text[:]) == "a   b   中", "got %q", string(expansion.text[:]))
	testing.expect(t, len(expansion.tabs) == 2)
	testing.expect(t, expansion.tabs[0] == shaping.Expanded_Tab{source_offset = 1, display_offset = 1, spaces = 3})
	testing.expect(t, expansion.tabs[1] == shaping.Expanded_Tab{source_offset = 3, display_offset = 5, spaces = 3})

	offsets := []struct{source, display: int}{{0, 0}, {1, 1}, {2, 4}, {3, 5}, {4, 8}, {7, 11}}
	for item in offsets {
		actual, ok := shaping.tab_display_offset(expansion, item.source)
		testing.expect(t, ok && actual == item.display)
	}
}

@(test)
test_tab_expansion_handles_combining_graphemes_and_invalid_input :: proc(t: ^testing.T) {
	expansion, err := shaping.expand_tabs("A\u0301\tB")
	if !expect_font_ok(t, err) {
		return
	}
	testing.expect(t, string(expansion.text[:]) == "A\u0301   B")
	caret, ok := shaping.tab_display_offset(expansion, 4)
	testing.expect(t, ok && caret == 6)
	shaping.tab_expansion_destroy(&expansion)

	_, width_err := shaping.expand_tabs("\t", 0)
	testing.expect(t, width_err.kind == .Invalid_Input)
	errs_destroy_shape(&width_err)
	invalid := [1]u8{0xff}
	_, utf8_err := shaping.expand_tabs(string(invalid[:]))
	testing.expect(t, utf8_err.kind == .Invalid_Input)
	errs_destroy_shape(&utf8_err)
}
