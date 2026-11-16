package textdeps_test

import "core:testing"

import ft "hammer:text/freetype"
import glyphcache "hammer:text/glyphcache"
import shaping "hammer:text/shaping"

shape_ligature :: proc(t: ^testing.T, text: string, native: rawptr, enabled: bool) -> shaping.Text {
	fonts := [1]shaping.Font{{font_id = 1, native = native}}
	result, err := shaping.shape(text, fonts[:], {pixel_size = 16, ligatures = enabled})
	if !expect_font_ok(t, err) {
		return {}
	}
	return result
}

ligature_visual_hash :: proc(t: ^testing.T, text: shaping.Text, native: rawptr) -> u64 {
	canvas := visual_canvas_init(48, 28)
	defer visual_canvas_destroy(&canvas)
	cache: glyphcache.Cache
	if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 64, page_height = 64, max_pages = 2, max_entries = 8})) {
		return 0
	}
	defer glyphcache.destroy(&cache)
	fonts := [1]shaping.Font{{font_id = 1, native = native}}
	if !visual_draw_text(t, &canvas, &cache, text, fonts[:], 2, 22) {
		return 0
	}
	testing.expect(t, canvas.ink > 0)
	return visual_hash(canvas.pixels)
}

@(test)
test_native_ligature_geometry_and_rasterization :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	native := rawptr(fixtures.ligature)
	enabled := shape_ligature(t, "fi", native, true)
	defer shaping.destroy(&enabled)
	disabled := shape_ligature(t, "fi", native, false)
	defer shaping.destroy(&disabled)
	if !testing.expect(t, len(enabled.runs) == 1 && len(disabled.runs) == 1) {
		return
	}
	ligated := enabled.runs[0]
	components := disabled.runs[0]
	if !testing.expect(t, len(ligated.glyphs) == 1 && len(components.glyphs) == 2) {
		return
	}
	f_id := ft.FT_Get_Char_Index(fixtures.ligature, ft.ULong('f'))
	i_id := ft.FT_Get_Char_Index(fixtures.ligature, ft.ULong('i'))
	testing.expect(t, ligated.glyphs[0].glyph_id != 0 && ligated.glyphs[0].glyph_id != f_id && ligated.glyphs[0].glyph_id != i_id)
	testing.expect(t, components.glyphs[0].glyph_id == f_id && components.glyphs[1].glyph_id == i_id)
	testing.expect(t, ligated.glyphs[0].x_advance == ligated.advance && ligated.advance == enabled.total_advance)
	testing.expect(t, components.glyphs[0].x_advance + components.glyphs[1].x_advance == components.advance)

	if testing.expect(t, len(ligated.clusters) == 2 && len(components.clusters) == 2) {
		testing.expect(t, ligated.clusters[0].source_start == 0 && ligated.clusters[0].source_end == 1)
		testing.expect(t, ligated.clusters[1].source_start == 1 && ligated.clusters[1].source_end == 2)
		testing.expect(t, ligated.clusters[0].advance == ligated.advance / 2)
		testing.expect(t, ligated.clusters[0].advance + ligated.clusters[1].advance == ligated.advance)
		testing.expect(t, components.clusters[0].advance == components.glyphs[0].x_advance)
		testing.expect(t, components.clusters[1].advance == components.glyphs[1].x_advance)
		middle := caret_x(t, enabled, 1, .Leading)
		testing.expect(t, middle == f32(ligated.advance) / 128)
		testing.expect(t, caret_x(t, enabled, 0, .Leading) == 0)
		testing.expect(t, caret_x(t, enabled, 2, .Trailing) == f32(ligated.advance) / 64)
		testing.expect(t, caret_x(t, disabled, 1, .Leading) == f32(components.glyphs[0].x_advance) / 64)
		hit, hit_ok := shaping.hit_test(enabled, middle)
		testing.expect(t, hit_ok && hit.offset == 1)
	}

	first, first_err := shaping.selection_spans(enabled, 0, 1)
	defer delete(first)
	if expect_font_ok(t, first_err) && testing.expect(t, len(first) == 1) {
		testing.expect(t, first[0].start == 0 && first[0].end == f32(ligated.advance) / 128)
	}
	second, second_err := shaping.selection_spans(enabled, 1, 2)
	defer delete(second)
	if expect_font_ok(t, second_err) && testing.expect(t, len(second) == 1) {
		testing.expect(t, second[0].start == f32(ligated.advance) / 128 && second[0].end == f32(ligated.advance) / 64)
	}

	cache: glyphcache.Cache
	if expect_font_ok(t, glyphcache.init(&cache, {page_width = 64, page_height = 64, max_pages = 2, max_entries = 8})) {
		defer glyphcache.destroy(&cache)
		entry, entry_err := glyphcache.get(&cache, shaping.cache_key(ligated, ligated.glyphs[0]), glyphcache.native_rasterize, native)
		if expect_font_ok(t, entry_err) {
			testing.expect(t, entry.page >= 0 && entry.rect.width > 0 && entry.rect.height > 0)
			testing.expect(t, entry.metrics.advance_x > 0)
		}
	}
	testing.expect(t, ligature_visual_hash(t, enabled, native) != ligature_visual_hash(t, disabled, native))
}

@(test)
test_programming_ligature_disable_calt :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	native := rawptr(fixtures.coding_ligature)
	enabled := shape_ligature(t, "==", native, true)
	defer shaping.destroy(&enabled)
	disabled := shape_ligature(t, "==", native, false)
	defer shaping.destroy(&disabled)
	if !testing.expect(t, len(enabled.runs) == 1 && len(disabled.runs) == 1) {
		return
	}
	ligated := enabled.runs[0]
	components := disabled.runs[0]
	if !testing.expect(t, len(ligated.glyphs) == 2 && len(components.glyphs) == 2) {
		return
	}
	equal_id := ft.FT_Get_Char_Index(fixtures.coding_ligature, ft.ULong('='))
	testing.expect(t, ligated.glyphs[0].glyph_id != 0 && ligated.glyphs[0].glyph_id != equal_id)
	testing.expect(t, ligated.glyphs[1].glyph_id != 0 && ligated.glyphs[1].glyph_id != equal_id)
	testing.expect(t, components.glyphs[0].glyph_id == equal_id && components.glyphs[1].glyph_id == equal_id)
	testing.expect(t, ligated.advance == components.advance)
	testing.expect(t, len(ligated.clusters) == 2 && len(components.clusters) == 2)
	testing.expect(t, ligature_visual_hash(t, enabled, native) != ligature_visual_hash(t, disabled, native))
}
