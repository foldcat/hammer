package glyphcache_test

import "core:testing"

import errs "hammer:core/errs"
import cachepkg "hammer:text/glyphcache"

Fake :: struct {
	calls:  int,
	width:  int,
	height: int,
	pitch:  int,
	fail:   bool,
	short:  bool,
	pixels: [4096]u8,
}

fake_rasterize :: proc(user: rawptr, key: cachepkg.Key, allocator := context.allocator) -> (cachepkg.Rasterized, errs.Error) {
	fake := (^Fake)(user)
	fake.calls += 1
	if fake.fail {
		return {}, errs.new(.IO, "injected rasterizer failure", allocator = allocator)
	}
	for i in 0 ..< fake.pitch * fake.height {
		fake.pixels[i] = u8(key.glyph_id)
	}
	data_len := fake.pitch * fake.height
	if fake.short {
		data_len = 1
	}
	return cachepkg.Rasterized{
		width = fake.width,
		height = fake.height,
		pitch = fake.pitch,
		pixels = fake.pixels[:data_len],
		metrics = {advance_x = i32(key.pixel_size)},
	}, errs.Error{}
}

test_key :: proc(glyph_id: u32) -> cachepkg.Key {
	return cachepkg.Key{font_id = 1, glyph_id = glyph_id, pixel_size = 16}
}

new_cache :: proc(t: ^testing.T, cache: ^cachepkg.Cache, options: cachepkg.Options) {
	if err := cachepkg.init(cache, options); !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		testing.expectf(t, false, "cache init failed: %s", desc)
		delete(desc, context.allocator)
		owned := err
		errs.destroy(&owned)
	}
}

expect_cache_ok :: proc(t: ^testing.T, entry: cachepkg.Entry, err: errs.Error) -> cachepkg.Entry {
	if !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		testing.expectf(t, false, "cache get failed: %s", desc)
		delete(desc, context.allocator)
		owned := err
		errs.destroy(&owned)
	}
	return entry
}

@(test)
test_complete_key_and_cache_hits :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 32, page_height = 32, max_pages = 4, max_entries = 32})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 2, height = 2, pitch = 2}

	base := test_key(1)
	cachepkg.get(&cache, base, fake_rasterize, &fake)
	cachepkg.get(&cache, base, fake_rasterize, &fake)
	testing.expect(t, fake.calls == 1)
	testing.expect(t, cache.stats.hits == 1 && cache.stats.misses == 1)

	keys := [?]cachepkg.Key{
		{font_id = 2, glyph_id = 1, pixel_size = 16},
		{font_id = 1, face_index = 1, glyph_id = 1, pixel_size = 16},
		{font_id = 1, glyph_id = 2, pixel_size = 16},
		{font_id = 1, glyph_id = 1, pixel_size = 17},
		{font_id = 1, glyph_id = 1, pixel_size = 16, render_mode = .Mono},
		{font_id = 1, glyph_id = 1, pixel_size = 16, variation_count = 1, variations = {{tag = 1, value = 1}, {}, {}, {}}},
	}
	for key in keys {
		cachepkg.get(&cache, key, fake_rasterize, &fake)
	}
	testing.expect(t, fake.calls == 7)
	testing.expect(t, cachepkg.entry_count(&cache) == 7)
}

@(test)
test_bitmap_copy_and_dirty_page :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 1, max_entries = 4})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 2, height = 2, pitch = 4}

	entry, err := cachepkg.get(&cache, test_key(7), fake_rasterize, &fake)
	expect_cache_ok(t, entry, err)
	testing.expect(t, entry.page == 0)
	testing.expect(t, entry.rect == cachepkg.Rect{x = 1, y = 1, width = 2, height = 2})
	testing.expect(t, entry.metrics.advance_x == 16)
	testing.expect(t, cachepkg.page_dirty(&cache, 0))
	pixels := cachepkg.page_pixels(&cache, 0)
	testing.expect(t, pixels[1 * 8 + 1] == 7 && pixels[2 * 8 + 2] == 7)
	testing.expect(t, pixels[0] == 0 && pixels[1 * 8 + 3] == 0)
	cachepkg.mark_page_clean(&cache, 0)
	testing.expect(t, !cachepkg.page_dirty(&cache, 0))

	cachepkg.get(&cache, test_key(7), fake_rasterize, &fake)
	testing.expect(t, !cachepkg.page_dirty(&cache, 0))
}

@(test)
test_lru_page_eviction_and_entry_budget :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 2, max_entries = 2})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 4, height = 4, pitch = 4}

	a, b, c := test_key(1), test_key(2), test_key(3)
	cachepkg.get(&cache, a, fake_rasterize, &fake)
	cachepkg.get(&cache, b, fake_rasterize, &fake)
	cachepkg.get(&cache, a, fake_rasterize, &fake)
	entry_c, err_c := cachepkg.get(&cache, c, fake_rasterize, &fake)
	expect_cache_ok(t, entry_c, err_c)
	testing.expect(t, cache.stats.evictions == 1)
	testing.expect(t, cachepkg.entry_count(&cache) == 2)
	testing.expect(t, entry_c.page == 1)
	testing.expect(t, cache.pages[1].dirty)

	cachepkg.get(&cache, a, fake_rasterize, &fake)
	testing.expect(t, fake.calls == 3)
	cachepkg.get(&cache, b, fake_rasterize, &fake)
	testing.expect(t, fake.calls == 4)
	testing.expect(t, cache.stats.evictions == 2)
	testing.expect(t, cachepkg.entry_count(&cache) == 2)
}

@(test)
test_invalid_inputs_preserve_existing_cache :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 1, max_entries = 4})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 2, height = 2, pitch = 2}
	cachepkg.get(&cache, test_key(1), fake_rasterize, &fake)

	_, invalid_err := cachepkg.get(&cache, {}, fake_rasterize, &fake)
	testing.expect(t, invalid_err.kind == .Invalid_Input)
	errs.destroy(&invalid_err)
	fake.width, fake.height, fake.pitch = 8, 8, 8
	_, large_err := cachepkg.get(&cache, test_key(2), fake_rasterize, &fake)
	testing.expect(t, large_err.kind == .Resource_Limit)
	errs.destroy(&large_err)
	fake.width, fake.height, fake.pitch = 2, 2, 4
	fake.short = true
	_, short_err := cachepkg.get(&cache, test_key(3), fake_rasterize, &fake)
	testing.expect(t, short_err.kind == .Invalid_Input)
	errs.destroy(&short_err)
	fake.width, fake.height, fake.pitch = 2, 2, 2
	fake.short = false
	fake.fail = true
	_, raster_err := cachepkg.get(&cache, test_key(4), fake_rasterize, &fake)
	testing.expect(t, raster_err.kind == .IO)
	errs.destroy(&raster_err)
	testing.expect(t, cachepkg.entry_count(&cache) == 1)
	testing.expect(t, len(cache.pages) == 1)
}

@(test)
test_empty_glyphs_clear_and_destroy :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 1, max_entries = 2})
	defer cachepkg.destroy(&cache)
	fake := Fake{}
	entry, err := cachepkg.get(&cache, test_key(1), fake_rasterize, &fake)
	expect_cache_ok(t, entry, err)
	testing.expect(t, entry.page == -1)
	testing.expect(t, cachepkg.entry_count(&cache) == 0 && len(cache.pages) == 0)

	fake.width, fake.height, fake.pitch = 2, 2, 2
	cachepkg.get(&cache, test_key(2), fake_rasterize, &fake)
	testing.expect(t, cachepkg.entry_count(&cache) == 1)
	cachepkg.clear(&cache)
	testing.expect(t, cachepkg.entry_count(&cache) == 0 && len(cache.pages) == 0)
	cachepkg.clear(&cache)
	cachepkg.destroy(&cache)
	cachepkg.destroy(&cache)
}

@(test)
test_reset_reuses_pages_and_forces_upload :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 1, max_entries = 2})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 2, height = 2, pitch = 2}
	_, err := cachepkg.get(&cache, test_key(1), fake_rasterize, &fake)
	expect_cache_ok(t, {}, err)
	page := &cache.pages[0]
	pixels := raw_data(page.pixels)
	keys := raw_data(page.keys)
	capacity := cap(page.keys)
	cachepkg.mark_page_clean(&cache, 0)

	cachepkg.reset(&cache)
	testing.expect(t, cachepkg.entry_count(&cache) == 0)
	testing.expect(t, len(cache.pages) == 1 && len(page.keys) == 0)
	testing.expect(t, raw_data(page.pixels) == pixels)
	testing.expect(t, raw_data(page.keys) == keys && cap(page.keys) == capacity)
	testing.expect(t, page.dirty && page.cursor_x == 1 && page.cursor_y == 1)
	testing.expect(t, page.pixels[1 * 8 + 1] == 0)

	entry, get_err := cachepkg.get(&cache, test_key(2), fake_rasterize, &fake)
	expect_cache_ok(t, entry, get_err)
	testing.expect(t, fake.calls == 2)
	testing.expect(t, cachepkg.entry_count(&cache) == 1)
	testing.expect(t, entry.rect == cachepkg.Rect{x = 1, y = 1, width = 2, height = 2})
}


FAKE_RGBA := [4]u8{10, 20, 30, 40}

fake_color_rasterize :: proc(user: rawptr, key: cachepkg.Key, allocator := context.allocator) -> (cachepkg.Rasterized, errs.Error) {
	return cachepkg.Rasterized{
		width = 1,
		height = 1,
		pitch = 4,
		pixels = FAKE_RGBA[:],
		format = .RGBA,
	}, {}
}

@(test)
test_alpha_and_rgba_pages_remain_separate :: proc(t: ^testing.T) {
	cache: cachepkg.Cache
	new_cache(t, &cache, {page_width = 8, page_height = 8, max_pages = 2, max_entries = 4})
	defer cachepkg.destroy(&cache)
	fake := Fake{width = 1, height = 1, pitch = 1}
	alpha, alpha_err := cachepkg.get(&cache, test_key(1), fake_rasterize, &fake)
	expect_cache_ok(t, alpha, alpha_err)
	color_key := test_key(2)
	color_key.render_mode = .Color
	color, color_err := cachepkg.get(&cache, color_key, fake_color_rasterize, nil)
	expect_cache_ok(t, color, color_err)

	testing.expect(t, alpha.page == 0 && color.page == 1)
	testing.expect(t, cache.pages[0].format == .Alpha && cache.pages[1].format == .RGBA)
	testing.expect(t, len(cache.pages[0].pixels) == 64 && len(cache.pages[1].pixels) == 256)
	testing.expect(t, cachepkg.page_channels(&cache, 0) == 1 && cachepkg.page_channels(&cache, 1) == 4)
	start := (color.rect.y * cache.pages[1].width + color.rect.x) * 4
	for value, index in FAKE_RGBA {
		testing.expect(t, cache.pages[1].pixels[start + index] == value)
	}
}
