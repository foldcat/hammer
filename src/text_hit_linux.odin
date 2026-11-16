#+build linux

package main

import "core:math"

import coords "core/coords"
import errs "core/errs"
import rope "core/rope"
import txn "core/txn"
import fonts "text/fonts"
import ft "text/freetype"
import shaping "text/shaping"

Text_Hit :: struct {
	offset:   int,
	affinity: txn.Affinity,
}

text_hit_test :: proc(pos: coords.Logical_Point, clamp_to_visible: bool) -> (Text_Hit, bool) {
	if math.is_nan(pos.x) || math.is_inf(pos.x) || math.is_nan(pos.y) || math.is_inf(pos.y) {
		return {}, false
	}
	win, _, ok := current_window()
	if !ok || win.body.width <= 0 || win.body.height <= 0 {
		return {}, false
	}
	body := win.body
	if !clamp_to_visible &&
		(pos.x < body.x || pos.x > body.x + body.width || pos.y < body.y || pos.y > body.y + body.height) {
		return {}, false
	}

	selected := fonts.face(&font_set, .Body)
	if selected == nil {
		return {}, false
	}
	pixel_size, size_ok := glyph_pixel_size(state.dpi.scale)
	if !size_ok || ft.FT_Set_Pixel_Sizes(ft.Face(selected.native), 0, pixel_size) != 0 {
		return {}, false
	}
	font_storage: [2]shaping.Font
	font_list := product_shaping_fonts(&font_storage)
	line_height := coords.points_to_logical_px(cfg.Font_Size_Points) * cfg.Line_Height
	if line_height <= 0 {
		return {}, false
	}
	line_count := min(
		rope.tree_line_count(&editor.doc.tree),
		MAX_VISIBLE_TEXT_LINES,
		int(body.height / line_height) + 1,
	)
	if line_count <= 0 {
		return {}, false
	}

	line_position := (pos.y - body.y - TEXT_PADDING) / line_height
	line_index := 0
	if line_position >= f32(line_count - 1) {
		line_index = line_count - 1
	} else if line_position > 0 {
		line_index = int(math.floor(line_position))
	}
	start, end, range_err := text_line_range(rope.Line_Index(line_index))
	if !errs.ok(range_err) {
		text_render_error(range_err)
		return {}, false
	}
	read_length := min(end - start, shaping.DEFAULT_VISIBLE_BYTES + shaping.VISIBLE_LOOKAHEAD_BYTES)
	line_bytes, read_err := rope.tree_read_all(
		&editor.doc.tree,
		{start, start + read_length},
		context.temp_allocator,
	)
	if !errs.ok(read_err) {
		text_render_error(read_err)
		return {}, false
	}
	expansion, tab_err := shaping.expand_tabs(string(line_bytes), shaping.DEFAULT_TAB_WIDTH, context.temp_allocator)
	if !errs.ok(tab_err) {
		text_render_error(tab_err)
		return {}, false
	}
	defer shaping.tab_expansion_destroy(&expansion)

	previous_allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = previous_allocator
	measurement: shaping.Measurement
	visible, shape_err := shaping.visible_next(
		string(expansion.text[:]),
		&measurement,
		font_list[:],
		{pixel_size = pixel_size, ligatures = cfg.Ligatures},
		shaping.DEFAULT_VISIBLE_BYTES,
		context.temp_allocator,
	)
	if !errs.ok(shape_err) {
		text_render_error(shape_err)
		return {}, false
	}
	defer shaping.destroy(&visible.text)

	hit, hit_ok := shaping.hit_test(visible.text, pos.x - body.x, state.dpi.scale)
	if !hit_ok {
		return {}, false
	}
	source_offset, source_ok := shaping.tab_source_offset(expansion, hit.offset)
	if !source_ok {
		return {}, false
	}
	affinity := txn.Affinity.Left
	if hit.edge == .Trailing {
		affinity = .Right
	}
	return Text_Hit{offset = start + source_offset, affinity = affinity}, true
}
