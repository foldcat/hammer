#+build linux

package main

import "core:log"

import errs "core/errs"
import fonts "text/fonts"
import shaping "text/shaping"

product_shape_visible :: proc(line: string, cursor: ^shaping.Measurement, pixel_size: u32) -> (shaping.Visible, errs.Error) {
	initial_cursor := cursor^
	storage: [shaping.MAX_FONTS]shaping.Font
	for _ in 0 ..< shaping.MAX_FONTS {
		cursor^ = initial_cursor
		font_list := product_shaping_fonts(&storage)
		visible, err := shaping.visible_next(
			line,
			cursor,
			font_list,
			{pixel_size = pixel_size, ligatures = cfg.Ligatures},
			shaping.DEFAULT_VISIBLE_BYTES,
			context.temp_allocator,
		)
		if !errs.ok(err) {
			return {}, err
		}
		added := false
		for diagnostic in visible.text.missing {
			if diagnostic.codepoint <= 0 {
				continue
			}
			fallback, fallback_err := fonts.ensure_fallback(&font_set, diagnostic.codepoint)
			if !errs.ok(fallback_err) {
				shaping.destroy(&visible.text)
				return {}, fallback_err
			}
			if fallback == nil {
				continue
			}
			already_loaded := false
			for font in font_list {
				already_loaded = already_loaded || font.font_id == fallback.cache_id
			}
			if already_loaded {
				continue
			}
			log.infof("fonts: fallback family=%q path=%s face_index=%d codepoint=U+%04X", fallback.family, fallback.path, fallback.face_index, diagnostic.codepoint)
			added = true
			break
		}
		if !added {
			return visible, {}
		}
		shaping.destroy(&visible.text)
	}
	return {}, errs.new(.Internal, "font fallback exceeded the shaping font budget", allocator = context.temp_allocator)
}
