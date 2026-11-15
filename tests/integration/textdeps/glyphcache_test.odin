package textdeps_test

import "core:os"
import "core:testing"

import fonts "hammer:text/fonts"
import glyphcache "hammer:text/glyphcache"

@(test)
test_native_freetype_glyph_cache :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-glyph-cache-*", context.temp_allocator)
	if !testing.expectf(t, sandbox_err == nil, "cannot create glyph cache sandbox: %v", sandbox_err) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}

	font_set: fonts.Set
	if !expect_font_ok(t, fonts.init(&font_set, font_options(config_path))) {
		return
	}
	defer fonts.destroy(&font_set)
	selected := fonts.face(&font_set, .Body)
	if !testing.expect(t, selected != nil) {
		return
	}

	cache: glyphcache.Cache
	if !expect_font_ok(t, glyphcache.init(&cache, {page_width = 64, page_height = 64, max_pages = 2, max_entries = 16})) {
		return
	}
	defer glyphcache.destroy(&cache)
	glyph_id, lookup_err := glyphcache.native_char_index(selected.native, 'A')
	if !expect_font_ok(t, lookup_err) {
		return
	}
	testing.expect(t, glyph_id != 0)
	key := glyphcache.Key{font_id = 1, glyph_id = glyph_id, pixel_size = 16}

	entry, err := glyphcache.get(&cache, key, glyphcache.native_rasterize, selected.native)
	if !expect_font_ok(t, err) {
		return
	}
	testing.expect(t, entry.page == 0 && entry.rect.width > 0 && entry.rect.height > 0)
	testing.expect(t, entry.metrics.advance_x > 0)
	testing.expect(t, cache.stats.misses == 1 && cache.stats.hits == 0)
	testing.expect(t, glyphcache.page_dirty(&cache, 0))
	pixels := glyphcache.page_pixels(&cache, 0)
	nonzero := false
	for pixel in pixels {
		nonzero = nonzero || pixel != 0
	}
	testing.expect(t, nonzero)

	cached, cached_err := glyphcache.get(&cache, key, glyphcache.native_rasterize, selected.native)
	if !expect_font_ok(t, cached_err) {
		return
	}
	testing.expect(t, cached == entry)
	testing.expect(t, cache.stats.hits == 1 && cache.stats.misses == 1)
}
