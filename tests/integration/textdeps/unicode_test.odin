package textdeps_test

import "core:testing"

import glyphcache "hammer:text/glyphcache"
import shaping "hammer:text/shaping"

COMBINING_MARKS_TEXT :: "A̋e̋i̋őű n͍ s͍ t͍ p̾ b̾ d̾ t̾ g̾ k̾ c̾ m̃ ñ l̃ r̃"
ZALGO_TEXT :: "Zͣaͣlͣgͣoͣ Tͣeͣsͣtͣ: Hͥeͣ cͦoͦmͦeͦsͣ"
VOWEL_STACKING_TEXT :: "Vowel stacking: ȁ ȅ ȉ ȍ ȕ y̏ ä̈ ë̈ ï̈ ö̈ ü̈"

expect_grapheme_layout :: proc(t: ^testing.T, text: shaping.Text) {
	for run in text.runs {
		for cluster in run.clusters {
			_, leading_ok := shaping.caret_position(text, cluster.source_start, .Leading)
			_, trailing_ok := shaping.caret_position(text, cluster.source_end, .Trailing)
			testing.expect(t, leading_ok && trailing_ok)
			spans, err := shaping.selection_spans(text, cluster.source_start, cluster.source_end)
			if expect_font_ok(t, err) {
				testing.expect(t, len(spans) > 0)
			}
			delete(spans)
		}
	}
}

rasterize_shaped_fixture :: proc(t: ^testing.T, text: shaping.Text, fonts: []shaping.Font) {
	cache: glyphcache.Cache
	if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 256, page_height = 256, max_pages = 8, max_entries = 256})) {
		return
	}
	defer glyphcache.destroy(&cache)
	ink_glyphs := 0
	for run in text.runs {
		native: rawptr
		for font in fonts {
			if font.font_id == run.font_id {
				native = font.native
				break
			}
		}
		if !testing.expect(t, native != nil) {
			continue
		}
		for glyph in run.glyphs {
			testing.expect(t, glyph.glyph_id != 0)
			entry, err := glyphcache.get(&cache, shaping.cache_key(run, glyph), glyphcache.native_rasterize, native)
			if expect_font_ok(t, err) && entry.page >= 0 && entry.rect.width > 0 && entry.rect.height > 0 {
				ink_glyphs += 1
			}
		}
	}
	testing.expect(t, ink_glyphs > 0)
}

@(test)
test_extended_combining_marks_shape_and_rasterize :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.latin)}}
	lines := [3]string{COMBINING_MARKS_TEXT, ZALGO_TEXT, VOWEL_STACKING_TEXT}
	for line in lines {
		result := shape_fixture(t, line, fonts[:])
		defer shaping.destroy(&result)
		testing.expect(t, len(result.missing) == 0 && len(result.runs) == 1)
		if len(result.runs) == 0 {
			continue
		}
		testing.expect(t, len(result.runs[0].glyphs) > len(result.runs[0].clusters))
		zero_advance_marks := 0
		for glyph in result.runs[0].glyphs {
			if glyph.x_advance == 0 {
				zero_advance_marks += 1
			}
		}
		testing.expect(t, zero_advance_marks > 0)
		expect_grapheme_layout(t, result)
		rasterize_shaped_fixture(t, result, fonts[:])
	}
}

@(test)
test_complex_indic_and_southeast_asian_shaping :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	cases := []struct {
		text:         string,
		face:         rawptr,
		cluster_count: int,
		min_glyphs:   int,
	} {
		{text = "नमस्ते", face = rawptr(fixtures.devanagari), cluster_count = 3, min_glyphs = 5},
		{text = "कि ख क्षि ज्ञ", face = rawptr(fixtures.devanagari), cluster_count = 7, min_glyphs = 7},
		{text = "வணக்கம்", face = rawptr(fixtures.tamil), cluster_count = 5, min_glyphs = 5},
		{text = "สวัสดี", face = rawptr(fixtures.thai), cluster_count = 4, min_glyphs = 6},
		{text = "សួស្តី", face = rawptr(fixtures.khmer), cluster_count = 2, min_glyphs = 5},
	}
	for test_case in cases {
		fonts := [1]shaping.Font{{font_id = 1, native = test_case.face}}
		result := shape_fixture(t, test_case.text, fonts[:])
		defer shaping.destroy(&result)
		if !testing.expect(t, len(result.missing) == 0 && len(result.runs) == 1) {
			continue
		}
		run := result.runs[0]
		testing.expect(t, run.font_id == 1 && run.direction == .LTR)
		testing.expectf(t, len(run.clusters) == test_case.cluster_count, "%q: got %d clusters", test_case.text, len(run.clusters))
		testing.expect(t, len(run.glyphs) >= test_case.min_glyphs)
		expect_grapheme_layout(t, result)
		rasterize_shaped_fixture(t, result, fonts[:])
	}
}

@(test)
test_mixed_bidi_script_fallback_and_layout :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [3]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.hebrew)},
		{font_id = 3, native = rawptr(fixtures.arabic)},
	}
	result := shape_fixture(t, "start אבג 123 مرحبا end", fonts[:])
	defer shaping.destroy(&result)
	testing.expect(t, len(result.missing) == 0 && len(result.runs) >= 4)
	seen_rtl := false
	seen_arabic := false
	for run in result.runs {
		seen_rtl = seen_rtl || run.direction == .RTL
		seen_arabic = seen_arabic || run.font_id == 3
	}
	testing.expect(t, seen_rtl && seen_arabic)
	expect_grapheme_layout(t, result)
	rasterize_shaped_fixture(t, result, fonts[:])
}

@(test)
test_box_block_braille_math_currency_and_technical_symbols :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	cases := []struct {
		text: string,
		face: rawptr,
	} {
		{text = "┌─┐└┘ ▀▄█ ∀∑∫√∞≠≤≥", face = rawptr(fixtures.math)},
		{text = "⠁⠃⠇⡿⣿ ⌘⌥⇧⏎", face = rawptr(fixtures.symbols2)},
		{text = "€£¥₹₿", face = rawptr(fixtures.latin)},
	}
	for test_case in cases {
		fonts := [1]shaping.Font{{font_id = 1, native = test_case.face}}
		result := shape_fixture(t, test_case.text, fonts[:])
		defer shaping.destroy(&result)
		testing.expect(t, len(result.missing) == 0 && len(result.runs) == 1)
		expect_grapheme_layout(t, result)
		rasterize_shaped_fixture(t, result, fonts[:])
	}
}
