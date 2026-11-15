package textdeps_test

import "core:testing"

import errs "hammer:core/errs"
import ft "hammer:text/freetype"
import shaping "hammer:text/shaping"

Fixture_Fonts :: struct {
	library: ft.Library,
	mono:    ft.Face,
	hebrew:  ft.Face,
	arabic:  ft.Face,
}

FIXTURE_HEBREW_FONT :: FIXTURE_DIR + "/FixtureHebrew.ttf"
FIXTURE_ARABIC_FONT :: FIXTURE_DIR + "/FixtureArabic.ttf"

fixture_fonts_open :: proc(t: ^testing.T) -> Fixture_Fonts {
	fixtures: Fixture_Fonts
	if !testing.expect(t, ft.FT_Init_FreeType(&fixtures.library) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_FONT, 0, &fixtures.mono) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_HEBREW_FONT, 0, &fixtures.hebrew) == 0) {
		return fixtures
	}
	testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_ARABIC_FONT, 0, &fixtures.arabic) == 0)
	return fixtures
}

fixture_fonts_destroy :: proc(fixtures: ^Fixture_Fonts) {
	if fixtures.arabic != nil {
		ft.FT_Done_Face(fixtures.arabic)
	}
	if fixtures.hebrew != nil {
		ft.FT_Done_Face(fixtures.hebrew)
	}
	if fixtures.mono != nil {
		ft.FT_Done_Face(fixtures.mono)
	}
	if fixtures.library != nil {
		ft.FT_Done_FreeType(fixtures.library)
	}
	fixtures^ = Fixture_Fonts{}
}

shape_fixture :: proc(t: ^testing.T, text: string, fonts: []shaping.Font) -> shaping.Text {
	result, err := shaping.shape(text, fonts, {pixel_size = 16})
	if !expect_font_ok(t, err) {
		return {}
	}
	return result
}

@(test)
test_shape_combining_cluster_and_cache_key :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	result := shape_fixture(t, "A\u0301", fonts[:])
	defer shaping.destroy(&result)

	testing.expect(t, len(result.runs) == 1)
	if len(result.runs) == 0 {
		return
	}
	run := result.runs[0]
	testing.expect(t, run.source_start == 0 && run.source_end == 3)
	testing.expect(t, run.direction == .LTR && run.advance > 0)
	testing.expect(t, len(run.glyphs) > 0)
	for glyph in run.glyphs {
		testing.expect(t, glyph.cluster == 0)
		key := shaping.cache_key(run, glyph)
		testing.expect(t, key.font_id == 1 && key.glyph_id == glyph.glyph_id && key.pixel_size == 16)
	}
	testing.expect(t, len(result.missing) == 0)
}

@(test)
test_shape_mixed_bidi_and_hebrew_fallback :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.hebrew)},
	}
	result := shape_fixture(t, "abc אבג", fonts[:])
	defer shaping.destroy(&result)

	testing.expectf(t, len(result.runs) == 2, "runs: got %d", len(result.runs))
	if len(result.runs) != 2 {
		return
	}
	testing.expect(t, result.runs[0].direction == .LTR && result.runs[0].font_id == 1)
	testing.expect(t, result.runs[1].direction == .RTL && result.runs[1].font_id == 2)
	testing.expect(t, result.runs[0].source_start == 0 && result.runs[0].source_end == 4)
	testing.expect(t, result.runs[1].source_start == 4 && result.runs[1].source_end == 10)
	hebrew_glyphs := result.runs[1].glyphs
	testing.expect(t, len(hebrew_glyphs) == 3)
	if len(hebrew_glyphs) == 3 {
		testing.expect(t, hebrew_glyphs[0].cluster == 8)
		testing.expect(t, hebrew_glyphs[1].cluster == 6)
		testing.expect(t, hebrew_glyphs[2].cluster == 4)
		for glyph in hebrew_glyphs {
			testing.expect(t, glyph.glyph_id != 0)
		}
	}
	testing.expect(t, len(result.missing) == 0)
	testing.expect(t, result.total_advance == result.runs[0].advance + result.runs[1].advance)
}

@(test)
test_shape_arabic_contextual_forms :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.arabic)},
	}
	result := shape_fixture(t, "مرحبا", fonts[:])
	defer shaping.destroy(&result)
	testing.expect(t, len(result.runs) == 1)
	if len(result.runs) == 0 {
		return
	}
	run := result.runs[0]
	testing.expect(t, run.direction == .RTL && run.font_id == 2)
	testing.expect(t, len(run.glyphs) == 6)
	testing.expect(t, run.glyphs[0].cluster == 8 && run.glyphs[5].cluster == 0)
	testing.expect(t, run.glyphs[1].cluster == 6 && run.glyphs[2].cluster == 6)
	testing.expect(t, run.glyphs[1].x_advance == 0)
	for glyph in run.glyphs {
		testing.expect(t, glyph.glyph_id != 0 && glyph.x_advance >= 0)
	}

	isolated := shape_fixture(t, "م", fonts[:])
	defer shaping.destroy(&isolated)
	if len(isolated.runs) > 0 && len(isolated.runs[0].glyphs) == 1 && len(run.glyphs) == 6 {
		testing.expect(t, run.glyphs[5].glyph_id != isolated.runs[0].glyphs[0].glyph_id)
	}
	testing.expect(t, len(result.missing) == 0)
}

@(test)
test_shape_missing_glyph_diagnostics :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	result := shape_fixture(t, "א", fonts[:])
	defer shaping.destroy(&result)
	testing.expect(t, len(result.missing) > 0)
	testing.expect(t, result.missing[0].codepoint == rune(0x05d0))
	testing.expect(t, result.missing[0].source_offset == 0)
}

@(test)
test_shape_invalid_input_and_empty :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	empty := shape_fixture(t, "", fonts[:])
	defer shaping.destroy(&empty)
	testing.expect(t, len(empty.runs) == 0 && empty.total_advance == 0)

	invalid_bytes := [1]u8{0xff}
	invalid, invalid_err := shaping.shape(string(invalid_bytes[:]), fonts[:], {pixel_size = 16})
	testing.expect(t, invalid_err.kind == .Invalid_Input)
	errs_destroy_shape(&invalid_err)
	shaping.destroy(&invalid)
	newline, newline_err := shaping.shape("a\nb", fonts[:], {pixel_size = 16})
	testing.expect(t, newline_err.kind == .Invalid_Input)
	errs_destroy_shape(&newline_err)
	shaping.destroy(&newline)
}

errs_destroy_shape :: proc(err: ^errs.Error) {
	errs.destroy(err)
}
