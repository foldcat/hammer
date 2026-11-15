package main

import "core:log"

import coords "core/coords"
import errs "core/errs"
import fonts "text/fonts"
import glyphcache "text/glyphcache"

glyph_cache: glyphcache.Cache
glyph_atlas: GPU_Glyph_Atlas
glyph_cache_ready := false

init_glyph_cache :: proc(scale: f32) {
	if fonts.face(&font_set, .Body) == nil {
		return
	}
	pixel_size_f, size_err := coords.points_to_physical_px(cfg.Font_Size_Points, scale)
	if !errs.ok(size_err) {
		log.errorf("glyph-cache: %v", errs.describe(size_err))
		errs.destroy(&size_err)
		return
	}
	pixel_size := u32(pixel_size_f + 0.5)
	if pixel_size == 0 {
		pixel_size = 1
	}
	if err := glyphcache.init(&glyph_cache, glyphcache.DEFAULT_OPTIONS, permanent()); !errs.ok(err) {
		log.errorf("glyph-cache: %v", errs.describe(err))
		errs.destroy(&err)
		return
	}

	roles := [3]fonts.Role{.Body, .Tag, .Console}
	for role in roles {
		selected := fonts.face(&font_set, role)
		if selected == nil {
			continue
		}
		glyph_id, lookup_err := glyphcache.native_char_index(selected.native, 'A')
		if !errs.ok(lookup_err) {
			log.errorf("glyph-cache: %v", errs.describe(lookup_err))
			errs.destroy(&lookup_err)
			glyph_cache_destroy()
			return
		}
		key := glyphcache.Key{
			font_id = u64(role) + 1,
			face_index = i32(selected.face_index),
			glyph_id = glyph_id,
			pixel_size = pixel_size,
		}
		if _, err := glyphcache.get(&glyph_cache, key, glyphcache.native_rasterize, selected.native); !errs.ok(err) {
			log.errorf("glyph-cache: %v", errs.describe(err))
			errs.destroy(&err)
			glyph_cache_destroy()
			return
		}
		if err := glyph_atlas_sync(&glyph_atlas, &glyph_cache); !errs.ok(err) {
			log.errorf("glyph-cache: %v", errs.describe(err))
			errs.destroy(&err)
			glyph_cache_destroy()
			return
		}
	}
	glyph_cache_ready = true
	log.infof(
		"glyph-cache: pages=%d entries=%d hits=%d misses=%d evictions=%d",
		len(glyph_cache.pages),
		glyphcache.entry_count(&glyph_cache),
		glyph_cache.stats.hits,
		glyph_cache.stats.misses,
		glyph_cache.stats.evictions,
	)
}

glyph_cache_destroy :: proc() {
	glyph_atlas_destroy(&glyph_atlas)
	glyphcache.destroy(&glyph_cache)
	glyph_cache_ready = false
}
