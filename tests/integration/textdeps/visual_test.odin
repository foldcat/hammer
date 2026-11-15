package textdeps_test

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import glyphcache "hammer:text/glyphcache"
import shaping "hammer:text/shaping"

Visual_Canvas :: struct {
	width, height: int,
	pixels:        []u8,
	ink:           int,
}

visual_canvas_init :: proc(width, height: int) -> Visual_Canvas {
	return Visual_Canvas{width = width, height = height, pixels = make([]u8, width * height)}
}

visual_canvas_destroy :: proc(canvas: ^Visual_Canvas) {
	delete(canvas.pixels)
	canvas^ = Visual_Canvas{}
}

visual_fixed_pixel :: proc(value: i32) -> int {
	return int(math.floor(f64(value) / 64 + 0.5))
}

visual_logical_pixel :: proc(value: f32) -> int {
	return int(math.floor(f64(value) + 0.5))
}

visual_fill_rect :: proc(canvas: ^Visual_Canvas, x, y, width, height: int, value: u8) {
	x0, y0 := max(0, x), max(0, y)
	x1, y1 := min(canvas.width, x + width), min(canvas.height, y + height)
	for row in y0 ..< y1 {
		for column in x0 ..< x1 {
			canvas.pixels[row * canvas.width + column] = value
		}
	}
}

visual_draw_text :: proc(
	t: ^testing.T,
	canvas: ^Visual_Canvas,
	cache: ^glyphcache.Cache,
	text: shaping.Text,
	fonts: []shaping.Font,
	origin_x, baseline: int,
) -> bool {
	for run in text.runs {
		native: rawptr
		for font in fonts {
			if font.font_id == run.font_id {
				native = font.native
				break
			}
		}
		if !testing.expect(t, native != nil) {
			return false
		}
		for glyph in run.glyphs {
			entry, err := glyphcache.get(cache, shaping.cache_key(run, glyph), glyphcache.native_rasterize, native)
			if !expect_font_ok(t, err) {
				return false
			}
			if entry.page < 0 {
				continue
			}
			page := glyphcache.page_pixels(cache, entry.page)
			page_width := cache.pages[entry.page].width
			dest_x := origin_x + visual_fixed_pixel(glyph.x) + int(entry.metrics.bearing_x)
			dest_y := baseline - visual_fixed_pixel(glyph.y) - int(entry.metrics.bearing_y)
			for row in 0 ..< entry.rect.height {
				for column in 0 ..< entry.rect.width {
					coverage := page[(entry.rect.y + row) * page_width + entry.rect.x + column]
					x, y := dest_x + column, dest_y + row
					if coverage == 0 || x < 0 || y < 0 || x >= canvas.width || y >= canvas.height {
						continue
					}
					index := y * canvas.width + x
					blended := u8(int(coverage) + (int(canvas.pixels[index]) * (255 - int(coverage)) + 127) / 255)
					if canvas.pixels[index] == 0 && blended > 0 {
						canvas.ink += 1
					}
					canvas.pixels[index] = blended
				}
			}
		}
	}
	return true
}

visual_shape_line :: proc(
	t: ^testing.T,
	canvas: ^Visual_Canvas,
	cache: ^glyphcache.Cache,
	line: string,
	fonts: []shaping.Font,
	pixel_size: u32,
	origin_x, baseline: int,
) -> shaping.Text {
	shaped, err := shaping.shape(line, fonts, {pixel_size = pixel_size})
	if !expect_font_ok(t, err) {
		return {}
	}
	if !visual_draw_text(t, canvas, cache, shaped, fonts, origin_x, baseline) {
		shaping.destroy(&shaped)
		return {}
	}
	return shaped
}

visual_uses_font :: proc(text: shaping.Text, font_id: u64) -> bool {
	for run in text.runs {
		if run.font_id == font_id {
			return true
		}
	}
	return false
}

visual_pgm :: proc(canvas: Visual_Canvas) -> []u8 {
	header := fmt.aprintf("P5\n%d %d\n255\n", canvas.width, canvas.height)
	defer delete(header)
	data := make([]u8, len(header) + len(canvas.pixels))
	copy(data, header)
	copy(data[len(header):], canvas.pixels)
	return data
}

visual_hash :: proc(pixels: []u8) -> u64 {
	hash := u64(14695981039346656037)
	for pixel in pixels {
		hash ~= u64(pixel)
		hash *= 1099511628211
	}
	return hash
}

visual_compare_golden :: proc(t: ^testing.T, name: string, canvas: Visual_Canvas, hash: u64) {
	actual := visual_pgm(canvas)
	defer delete(actual)
	update_root, updating := os.lookup_env("HAMMER_WRITE_GOLDEN", context.temp_allocator)
	if updating && update_root != "" {
		if !os.exists(update_root) {
			if err := os.make_directory_all(update_root); !testing.expectf(t, err == nil, "cannot create golden output directory: %v", err) {
				return
			}
		}
		path := fmt.tprintf("%s/mixed-%s.pgm", update_root, name)
		if err := os.write_entire_file(path, actual); !testing.expectf(t, err == nil, "cannot write golden %s: %v", path, err) {
			return
		}
		fmt.printf("visual-golden: scale=%s hash=%016x path=%s\n", name, hash, path)
		return
	}

	path := fmt.tprintf("%sgolden/mixed-%s.pgm", #directory, name)
	expected, err := os.read_entire_file(path, context.allocator)
	defer delete(expected, context.allocator)
	if !testing.expectf(t, err == nil, "cannot read golden %s: %v", path, err) {
		return
	}
	if !testing.expectf(t, len(expected) == len(actual), "golden %s length changed", path) {
		return
	}
	for byte, index in actual {
		if byte != expected[index] {
			testing.expectf(t, false, "golden %s differs at byte %d; actual hash=%016x", path, index, hash)
			return
		}
	}
	fmt.printf("visual-golden: scale=%s hash=%016x matched\n", name, hash)
}

@(test)
test_visual_mixed_scripts_and_dpi :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	mono_cjk := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.cjk)},
	}
	mono_emoji := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 3, native = rawptr(fixtures.emoji)},
	}
	mono_hebrew := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 4, native = rawptr(fixtures.hebrew)},
	}
	mono_arabic := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 5, native = rawptr(fixtures.arabic)},
	}
	mono := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}

	scales := [4]f32{1, 1.25, 1.5, 2}
	names := [4]string{"100", "125", "150", "200"}
	hashes: [4]u64
	for scale, scale_index in scales {
		pixel_size := u32(16 * scale + 0.5)
		canvas := visual_canvas_init(visual_logical_pixel(320 * scale), visual_logical_pixel(192 * scale))
		defer visual_canvas_destroy(&canvas)
		cache: glyphcache.Cache
		if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 256, page_height = 256, max_pages = 4, max_entries = 256})) {
			return
		}
		defer glyphcache.destroy(&cache)
		origin_x := visual_logical_pixel(8 * scale)

		latin_cjk := visual_shape_line(t, &canvas, &cache, "A\u0301 CJK 漢字界", mono_cjk[:], pixel_size, origin_x, visual_logical_pixel(24 * scale))
		defer shaping.destroy(&latin_cjk)
		testing.expect(t, len(latin_cjk.missing) == 0 && visual_uses_font(latin_cjk, 2))
		emoji := visual_shape_line(t, &canvas, &cache, "Emoji 👩\u200d💻", mono_emoji[:], pixel_size, origin_x, visual_logical_pixel(52 * scale))
		defer shaping.destroy(&emoji)
		testing.expect(t, len(emoji.missing) == 0 && visual_uses_font(emoji, 3))

		hebrew, hebrew_err := shaping.shape("abc אבג", mono_hebrew[:], {pixel_size = pixel_size})
		expect_font_ok(t, hebrew_err)
		defer shaping.destroy(&hebrew)
		testing.expect(t, len(hebrew.missing) == 0)
		spans, spans_err := shaping.selection_spans(hebrew, 2, 6, scale)
		if expect_font_ok(t, spans_err) {
			testing.expect(t, len(spans) > 0)
			for span in spans {
				x := origin_x + visual_logical_pixel(span.start * scale)
				width := visual_logical_pixel((span.end - span.start) * scale)
				visual_fill_rect(&canvas, x, visual_logical_pixel(60 * scale), width, visual_logical_pixel(24 * scale), 48)
			}
		}
		delete(spans)
		caret_x, caret_ok := shaping.caret_position(hebrew, 4, .Trailing, scale)
		if testing.expect(t, caret_ok) {
			x := origin_x + visual_logical_pixel(caret_x * scale)
			visual_fill_rect(&canvas, x, visual_logical_pixel(60 * scale), max(1, visual_logical_pixel(scale)), visual_logical_pixel(24 * scale), 128)
		}
		visual_draw_text(t, &canvas, &cache, hebrew, mono_hebrew[:], origin_x, visual_logical_pixel(80 * scale))

		arabic := visual_shape_line(t, &canvas, &cache, "مرحبا", mono_arabic[:], pixel_size, origin_x, visual_logical_pixel(108 * scale))
		defer shaping.destroy(&arabic)
		testing.expect(t, len(arabic.missing) == 0)
		bidi := visual_shape_line(t, &canvas, &cache, "bidi \u202eאבג\u202c end", mono_hebrew[:], pixel_size, origin_x, visual_logical_pixel(136 * scale))
		defer shaping.destroy(&bidi)

		cursor: shaping.Measurement
		segmented, segmented_err := shaping.visible_next("segmented: abcdefghijklmnopqrstuvwxyz", &cursor, mono[:], {pixel_size = pixel_size}, 16)
		if expect_font_ok(t, segmented_err) {
			testing.expect(t, segmented.segmented && !segmented.done)
			visual_draw_text(t, &canvas, &cache, segmented.text, mono[:], origin_x, visual_logical_pixel(164 * scale))
			visual_fill_rect(&canvas, visual_logical_pixel(304 * scale), visual_logical_pixel(148 * scale), max(1, visual_logical_pixel(4 * scale)), visual_logical_pixel(20 * scale), 96)
		}
		shaping.destroy(&segmented.text)

		testing.expect(t, canvas.ink > 100)
		hash := visual_hash(canvas.pixels)
		hashes[scale_index] = hash
		visual_compare_golden(t, names[scale_index], canvas, hash)
	}
	for index in 1 ..< len(hashes) {
		testing.expect(t, hashes[index] != hashes[0])
	}
}
