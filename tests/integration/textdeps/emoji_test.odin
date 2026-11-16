package textdeps_test

import "core:os"
import "core:testing"

import fonts "hammer:text/fonts"
import glyphcache "hammer:text/glyphcache"
import shaping "hammer:text/shaping"

EMOJI_SEQUENCE_TEXT :: "A👩\u200d💻👍🏽👨\u200d👩\u200d👧\u200d👦❤️🇨🇦1️⃣B"

shape_emoji_with_mono :: proc(t: ^testing.T, text: string, fixtures: ^Fixture_Fonts, pixel_size: u32) -> shaping.Text {
	fonts := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.color_emoji)},
	}
	result, err := shaping.shape(text, fonts[:], {pixel_size = pixel_size})
	if !expect_font_ok(t, err) {
		return {}
	}
	return result
}

expect_color_pixels :: proc(t: ^testing.T, cache: ^glyphcache.Cache, entry: glyphcache.Entry, require_color := false) {
	if !testing.expect(t, entry.page >= 0 && entry.page < len(cache.pages)) {
		return
	}
	page := &cache.pages[entry.page]
	testing.expect(t, page.format == .RGBA && glyphcache.page_channels(cache, entry.page) == 4)
	pixels := glyphcache.page_pixels(cache, entry.page)
	colored := false
	premultiplied := true
	for y in 0 ..< entry.rect.height {
		for x in 0 ..< entry.rect.width {
			index := ((entry.rect.y + y) * page.width + entry.rect.x + x) * 4
			r, g, b, a := pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]
			if a > 0 && (r != g || g != b) {
				colored = true
			}
			premultiplied = premultiplied && r <= a && g <= a && b <= a
		}
	}
	if require_color {
		testing.expect(t, colored)
	}
	testing.expect(t, premultiplied)
}

@(test)
test_full_emoji_sequences_shape_and_rasterize_in_color :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	result := shape_emoji_with_mono(t, EMOJI_SEQUENCE_TEXT, &fixtures, 16)
	defer shaping.destroy(&result)
	if !testing.expect(t, len(result.runs) == 3) {
		return
	}
	testing.expect(t, result.runs[0].font_id == 1 && result.runs[2].font_id == 1)
	run := result.runs[1]
	testing.expect(t, run.font_id == 2 && run.render_mode == .Color)
	testing.expect(t, run.source_start == 1 && run.source_end == 66)
	if !testing.expect(t, len(run.glyphs) == 6 && len(run.clusters) == 6) {
		return
	}
	starts := [6]int{1, 12, 20, 45, 51, 59}
	ends := [6]int{12, 20, 45, 51, 59, 66}
	seen_ids: [6]u32
	for glyph, index in run.glyphs {
		testing.expect(t, glyph.glyph_id != 0 && glyph.cluster == starts[index])
		testing.expect(t, glyph.x_advance > 0)
		seen_ids[index] = glyph.glyph_id
		for previous in 0 ..< index {
			testing.expect(t, glyph.glyph_id != seen_ids[previous])
		}
	}
	for cluster, index in run.clusters {
		testing.expect(t, cluster.source_start == starts[index] && cluster.source_end == ends[index])
		_, leading_ok := shaping.caret_position(result, cluster.source_start, .Leading)
		_, trailing_ok := shaping.caret_position(result, cluster.source_end, .Trailing)
		testing.expect(t, leading_ok && trailing_ok)
	}

	cache: glyphcache.Cache
	if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 64, page_height = 64, max_pages = 4, max_entries = 16})) {
		return
	}
	defer glyphcache.destroy(&cache)
	for glyph in run.glyphs {
		entry, err := glyphcache.get(&cache, shaping.cache_key(run, glyph), glyphcache.native_rasterize, rawptr(fixtures.color_emoji))
		if !expect_font_ok(t, err) {
			continue
		}
		testing.expect(t, entry.rect.width > 0 && entry.rect.height > 0)
		testing.expect(t, entry.metrics.advance_x > 0 && entry.metrics.bearing_y > 0)
		expect_color_pixels(t, &cache, entry, glyph.cluster == 45)
	}
}

@(test)
test_color_emoji_scales_with_dpi_without_splitting_graphemes :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	cache: glyphcache.Cache
	if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 128, page_height = 128, max_pages = 4, max_entries = 16})) {
		return
	}
	defer glyphcache.destroy(&cache)
	sizes := [4]u32{16, 20, 24, 32}
	previous_width := 0
	previous_advance := i32(0)
	for pixel_size in sizes {
		result := shape_emoji_with_mono(t, "👨\u200d👩\u200d👧\u200d👦", &fixtures, pixel_size)
		defer shaping.destroy(&result)
		if !testing.expect(t, len(result.runs) == 1 && len(result.runs[0].glyphs) == 1 && len(result.runs[0].clusters) == 1) {
			continue
		}
		run := result.runs[0]
		testing.expect(t, run.clusters[0].source_start == 0 && run.clusters[0].source_end == 25)
		testing.expect(t, run.advance > previous_advance)
		previous_advance = run.advance
		entry, err := glyphcache.get(&cache, shaping.cache_key(run, run.glyphs[0]), glyphcache.native_rasterize, rawptr(fixtures.color_emoji))
		if expect_font_ok(t, err) {
			testing.expect(t, entry.rect.width > previous_width)
			previous_width = entry.rect.width
			expect_color_pixels(t, &cache, entry)
		}
		spans, span_err := shaping.selection_spans(result, 0, 25)
		defer delete(spans)
		if expect_font_ok(t, span_err) {
			testing.expect(t, len(spans) == 1 && spans[0].end > spans[0].start)
		}
	}
}


@(test)
test_optional_color_emoji_font_role :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-emoji-font-*", context.temp_allocator)
	if !testing.expect(t, sandbox_err == nil) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}
	options := font_options(config_path)
	options.roles[int(fonts.Role.Emoji)] = {path = FIXTURE_COLOR_EMOJI_FONT}
	set: fonts.Set
	if !expect_font_ok(t, fonts.init(&set, options)) {
		return
	}
	defer fonts.destroy(&set)
	selected := fonts.face(&set, .Emoji)
	testing.expect(t, selected != nil && selected.family == "Noto Color Emoji")
}
