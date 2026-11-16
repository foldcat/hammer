package textdeps_test

import "core:testing"

import errs "hammer:core/errs"
import ft "hammer:text/freetype"
import shaping "hammer:text/shaping"

Fixture_Fonts :: struct {
	library:         ft.Library,
	mono:            ft.Face,
	latin:           ft.Face,
	hebrew:          ft.Face,
	arabic:          ft.Face,
	devanagari:      ft.Face,
	thai:            ft.Face,
	khmer:           ft.Face,
	tamil:           ft.Face,
	cjk:             ft.Face,
	emoji:           ft.Face,
	ligature:        ft.Face,
	coding_ligature: ft.Face,
	color_emoji:     ft.Face,
	math:            ft.Face,
	symbols2:        ft.Face,
}

FIXTURE_LATIN_FONT :: FIXTURE_DIR + "/FixtureLatin.ttf"
FIXTURE_HEBREW_FONT :: FIXTURE_DIR + "/FixtureHebrew.ttf"
FIXTURE_ARABIC_FONT :: FIXTURE_DIR + "/FixtureArabic.ttf"
FIXTURE_DEVANAGARI_FONT :: FIXTURE_DIR + "/FixtureDevanagari.ttf"
FIXTURE_THAI_FONT :: FIXTURE_DIR + "/FixtureThai.ttf"
FIXTURE_KHMER_FONT :: FIXTURE_DIR + "/FixtureKhmer.ttf"
FIXTURE_TAMIL_FONT :: FIXTURE_DIR + "/FixtureTamil.ttf"
FIXTURE_CJK_FONT :: FIXTURE_DIR + "/FixtureCJK.otf"
FIXTURE_EMOJI_FONT :: FIXTURE_DIR + "/FixtureEmoji.ttf"
FIXTURE_LIGATURE_FONT :: FIXTURE_DIR + "/FixtureLigature.ttf"
FIXTURE_CODING_LIGATURE_FONT :: FIXTURE_DIR + "/FixtureCodingLigature.ttf"
FIXTURE_COLOR_EMOJI_FONT :: FIXTURE_DIR + "/FixtureColorEmoji.ttf"
FIXTURE_MATH_FONT :: FIXTURE_DIR + "/FixtureMath.ttf"
FIXTURE_SYMBOLS2_FONT :: FIXTURE_DIR + "/FixtureSymbols2.ttf"

fixture_fonts_open :: proc(t: ^testing.T) -> Fixture_Fonts {
	fixtures: Fixture_Fonts
	if !testing.expect(t, ft.FT_Init_FreeType(&fixtures.library) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_FONT, 0, &fixtures.mono) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_LATIN_FONT, 0, &fixtures.latin) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_HEBREW_FONT, 0, &fixtures.hebrew) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_ARABIC_FONT, 0, &fixtures.arabic) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_DEVANAGARI_FONT, 0, &fixtures.devanagari) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_THAI_FONT, 0, &fixtures.thai) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_KHMER_FONT, 0, &fixtures.khmer) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_TAMIL_FONT, 0, &fixtures.tamil) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_CJK_FONT, 0, &fixtures.cjk) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_EMOJI_FONT, 0, &fixtures.emoji) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_LIGATURE_FONT, 0, &fixtures.ligature) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_CODING_LIGATURE_FONT, 0, &fixtures.coding_ligature) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_COLOR_EMOJI_FONT, 0, &fixtures.color_emoji) == 0) {
		return fixtures
	}
	if !testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_MATH_FONT, 0, &fixtures.math) == 0) {
		return fixtures
	}
	testing.expect(t, ft.FT_New_Face(fixtures.library, FIXTURE_SYMBOLS2_FONT, 0, &fixtures.symbols2) == 0)
	return fixtures
}

fixture_fonts_destroy :: proc(fixtures: ^Fixture_Fonts) {
	if fixtures.symbols2 != nil {
		ft.FT_Done_Face(fixtures.symbols2)
	}
	if fixtures.math != nil {
		ft.FT_Done_Face(fixtures.math)
	}
	if fixtures.color_emoji != nil {
		ft.FT_Done_Face(fixtures.color_emoji)
	}
	if fixtures.coding_ligature != nil {
		ft.FT_Done_Face(fixtures.coding_ligature)
	}
	if fixtures.ligature != nil {
		ft.FT_Done_Face(fixtures.ligature)
	}
	if fixtures.emoji != nil {
		ft.FT_Done_Face(fixtures.emoji)
	}
	if fixtures.cjk != nil {
		ft.FT_Done_Face(fixtures.cjk)
	}
	if fixtures.tamil != nil {
		ft.FT_Done_Face(fixtures.tamil)
	}
	if fixtures.khmer != nil {
		ft.FT_Done_Face(fixtures.khmer)
	}
	if fixtures.thai != nil {
		ft.FT_Done_Face(fixtures.thai)
	}
	if fixtures.devanagari != nil {
		ft.FT_Done_Face(fixtures.devanagari)
	}
	if fixtures.arabic != nil {
		ft.FT_Done_Face(fixtures.arabic)
	}
	if fixtures.hebrew != nil {
		ft.FT_Done_Face(fixtures.hebrew)
	}
	if fixtures.latin != nil {
		ft.FT_Done_Face(fixtures.latin)
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

@(test)
test_hit_test_combining_and_emoji_graphemes :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	result := shape_fixture(t, "A\u0301👩\u200d💻B", fonts[:])
	defer shaping.destroy(&result)
	if !testing.expect(t, len(result.runs) == 1) {
		return
	}
	run := result.runs[0]
	if !testing.expect(t, len(run.clusters) == 3) {
		return
	}
	starts := [3]int{0, 3, 14}
	ends := [3]int{3, 14, 15}
	fractions := [2]f32{0.25, 0.75}
	for cluster, index in run.clusters {
		testing.expect(t, cluster.source_start == starts[index] && cluster.source_end == ends[index])
		for fraction in fractions {
			x := (f32(cluster.x) + f32(cluster.advance) * fraction) / 64
			hit, ok := shaping.hit_test(result, x)
			expected := cluster.source_start
			if fraction > 0.5 {
				expected = cluster.source_end
			}
			testing.expect(t, ok && hit.offset == expected)
		}
	}
	for offset in 0 ..= 15 {
		_, ok := shaping.caret_position(result, offset, .Leading)
		expected := offset == 0 || offset == 3 || offset == 14 || offset == 15
		testing.expectf(t, ok == expected, "caret validity at byte %d: got %v", offset, ok)
	}
	for offset in starts {
		x := caret_x(t, result, offset, .Leading)
		hit, ok := shaping.hit_test(result, x)
		testing.expect(t, ok && hit.offset == offset)
	}
	x := caret_x(t, result, 15, .Trailing)
	hit, ok := shaping.hit_test(result, x)
	testing.expect(t, ok && hit.offset == 15)
}

@(test)
test_hit_test_synthetic_ligature_grapheme_positions :: proc(t: ^testing.T) {
	result := shaping.Text{
		runs = make([dynamic]shaping.Run),
		total_advance = 600,
	}
	run := shaping.Run{
		source_start = 0,
		source_end = 4,
		direction = .RTL,
		glyphs = make([dynamic]shaping.Glyph, 1),
		clusters = make([dynamic]shaping.Cluster, 2),
		advance = 600,
	}
	run.glyphs[0] = {cluster = 0, x_advance = 600}
	run.clusters[0] = {source_start = 2, source_end = 4, x = 0, advance = 300}
	run.clusters[1] = {source_start = 0, source_end = 2, x = 300, advance = 300}
	append(&result.runs, run)
	defer shaping.destroy(&result)

	start := caret_x(t, result, 0, .Leading)
	middle := caret_x(t, result, 2, .Leading)
	end := caret_x(t, result, 4, .Trailing)
	testing.expect(t, end == 0 && middle == 300.0 / 64 && start == 600.0 / 64)
	hit, ok := shaping.hit_test(result, middle)
	testing.expect(t, ok && hit.offset == 2 && hit.x == middle)

	lam, lam_err := shaping.selection_spans(result, 0, 2)
	testing.expect(t, errs.ok(lam_err))
	defer delete(lam)
	alef, alef_err := shaping.selection_spans(result, 2, 4)
	testing.expect(t, errs.ok(alef_err))
	defer delete(alef)
	if testing.expect(t, len(lam) == 1 && len(alef) == 1) {
		testing.expect(t, lam[0].start == middle && lam[0].end == start)
		testing.expect(t, alef[0].start == end && alef[0].end == middle)
	}
}

@(test)
test_hit_test_rtl_edges_and_round_trips :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.hebrew)}}
	result := shape_fixture(t, "אבג", fonts[:])
	defer shaping.destroy(&result)
	if !testing.expect(t, len(result.runs) == 1) {
		return
	}
	run := result.runs[0]
	if !testing.expect(t, run.direction == .RTL && len(run.clusters) == 3) {
		return
	}
	for cluster, index in run.clusters {
		testing.expect(t, cluster.source_start == 4 - 2 * index && cluster.source_end == 6 - 2 * index)
		left := f32(cluster.x) / 64
		right := f32(cluster.x + cluster.advance) / 64
		testing.expect(t, caret_x(t, result, cluster.source_start, .Leading) == right)
		testing.expect(t, caret_x(t, result, cluster.source_end, .Trailing) == left)
		left_hit, left_ok := shaping.hit_test(result, left + f32(cluster.advance) / 256)
		testing.expect(t, left_ok && left_hit.offset == cluster.source_end && left_hit.edge == .Trailing)
		right_hit, right_ok := shaping.hit_test(result, right - f32(cluster.advance) / 256)
		testing.expect(t, right_ok && right_hit.offset == cluster.source_start && right_hit.edge == .Leading)
		edges := [2]shaping.Edge{.Leading, .Trailing}
		for edge in edges {
			offset := cluster.source_start
			if edge == .Trailing {
				offset = cluster.source_end
			}
			x := caret_x(t, result, offset, edge)
			hit, ok := shaping.hit_test(result, x)
			testing.expect(t, ok && hit.offset == offset)
		}
	}
}

@(test)
test_hit_test_mixed_bidi_affinity_and_selection :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.hebrew)},
	}
	result := shape_fixture(t, "abc אבג", fonts[:])
	defer shaping.destroy(&result)
	if !testing.expect(t, len(result.runs) == 2) {
		return
	}
	ltr_end := caret_x(t, result, 4, .Trailing)
	rtl_start := caret_x(t, result, 4, .Leading)
	testing.expect(t, ltr_end == f32(result.runs[0].advance) / 64)
	testing.expect(t, rtl_start == f32(result.total_advance) / 64 && rtl_start > ltr_end)
	ltr_hit, ltr_ok := shaping.hit_test(result, ltr_end)
	testing.expect(t, ltr_ok && ltr_hit.offset == 4 && ltr_hit.edge == .Trailing)
	rtl_hit, rtl_ok := shaping.hit_test(result, rtl_start)
	testing.expect(t, rtl_ok && rtl_hit.offset == 4 && rtl_hit.edge == .Leading)

	spans, span_err := shaping.selection_spans(result, 2, 6)
	testing.expect(t, errs.ok(span_err))
	defer delete(spans)
	if testing.expect(t, len(spans) == 2) {
		testing.expect(t, spans[0].start == caret_x(t, result, 2, .Leading) && spans[0].end == ltr_end)
		testing.expect(t, spans[1].start == caret_x(t, result, 6, .Leading) && spans[1].end == rtl_start)
	}
	all, all_err := shaping.selection_spans(result, 10, 0)
	testing.expect(t, errs.ok(all_err))
	defer delete(all)
	if testing.expect(t, len(all) == 1) {
		testing.expect(t, all[0].start == 0 && all[0].end == f32(result.total_advance) / 64)
	}

	invalid, invalid_err := shaping.selection_spans(result, 4, 5)
	testing.expect(t, invalid_err.kind == .Invalid_Input && len(invalid) == 0)
	delete(invalid)
	errs_destroy_shape(&invalid_err)
}

@(test)
test_hit_test_empty_text :: proc(t: ^testing.T) {
	result := shaping.Text{}
	hit, ok := shaping.hit_test(result, 100)
	testing.expect(t, ok && hit.offset == 0 && hit.edge == .Leading && hit.x == 0)
	_, start_ok := shaping.caret_position(result, 0, .Leading)
	_, end_ok := shaping.caret_position(result, 0, .Trailing)
	_, invalid_ok := shaping.caret_position(result, 1, .Leading)
	testing.expect(t, start_ok && end_ok && !invalid_ok)
	spans, err := shaping.selection_spans(result, 0, 0)
	testing.expect(t, errs.ok(err) && len(spans) == 0)
	delete(spans)
}

@(test)
test_hit_test_fractional_dpi_scale :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	result := shape_fixture(t, "abc", fonts[:])
	defer shaping.destroy(&result)
	scales := [2]f32{1.25, 2}
	for scale in scales {
		for offset in 0 ..= 3 {
			x, ok := shaping.caret_position(result, offset, .Leading, scale)
			testing.expect(t, ok)
			hit, hit_ok := shaping.hit_test(result, x, scale)
			testing.expect(t, hit_ok && hit.offset == offset && hit.x == x)
		}
		spans, err := shaping.selection_spans(result, 0, 3, scale)
		testing.expect(t, errs.ok(err) && len(spans) == 1)
		if len(spans) == 1 {
			testing.expect(t, spans[0].start == 0 && spans[0].end == f32(result.total_advance) / (64 * scale))
		}
		delete(spans)
	}
	_, hit_ok := shaping.hit_test(result, 0, 0)
	_, caret_ok := shaping.caret_position(result, 0, .Leading, 0)
	testing.expect(t, !hit_ok && !caret_ok)
	invalid, invalid_err := shaping.selection_spans(result, 0, 3, 0)
	testing.expect(t, invalid_err.kind == .Invalid_Input && len(invalid) == 0)
	delete(invalid)
	errs_destroy_shape(&invalid_err)
}

@(test)
test_missing_glyph_diagnostics_are_bounded :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	bytes := make([]u8, 200)
	defer delete(bytes)
	for index := 0; index < len(bytes); index += 2 {
		bytes[index] = 0xd7
		bytes[index + 1] = 0x90
	}
	result := shape_fixture(t, string(bytes), fonts[:])
	defer shaping.destroy(&result)
	testing.expect(t, len(result.missing) == shaping.MAX_MISSING_DIAGNOSTICS)
}

caret_x :: proc(t: ^testing.T, text: shaping.Text, offset: int, edge: shaping.Edge, scale := f32(1)) -> f32 {
	x, ok := shaping.caret_position(text, offset, edge, scale)
	testing.expectf(t, ok, "caret position at byte %d, edge %v", offset, edge)
	return x
}

errs_destroy_shape :: proc(err: ^errs.Error) {
	errs.destroy(err)
}
