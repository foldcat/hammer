#+build linux, windows

package main

import "core:math"

import config "core/config"
import coords "core/coords"
import errs "core/errs"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"
import fonts "text/fonts"
import glyphcache "text/glyphcache"
import shaping "text/shaping"

Text_Hit :: struct {
	offset:   int,
	affinity: txn.Affinity,
}

text_hit_test :: proc(pos: coords.Logical_Point, clamp_to_visible: bool, body: layout.Rect, first_line: rope.Line_Index, wrap_mode: config.Wrap_Mode, horizontal_offset: ^f32, doc: ^txn.Doc) -> (Text_Hit, bool) {
	if math.is_nan(pos.x) || math.is_inf(pos.x) || math.is_nan(pos.y) || math.is_inf(pos.y) {
		return {}, false
	}
	if doc == nil || body.width <= 0 || body.height <= 0 || first_line < 0 {
		return {}, false
	}
	if !clamp_to_visible &&
		(pos.x < body.x || pos.x > body.x + body.width || pos.y < body.y || pos.y > body.y + body.height) {
		return {}, false
	}

	selected := fonts.face(&font_set, .Body)
	if selected == nil {
		return {}, false
	}
	pixel_size, size_ok := glyph_pixel_size(state.dpi.scale)
	if !size_ok {
		return {}, false
	}
	if _, size_err := glyphcache.native_set_pixel_size(selected.native, pixel_size); !errs.ok(size_err) {
		text_render_error(size_err)
		return {}, false
	}
	line_height := coords.points_to_logical_px(state.dpi.points) * cfg.Line_Height
	if line_height <= 0 {
		return {}, false
	}
	line_count := min(max(0, rope.tree_line_count(&doc.tree) - int(first_line)), MAX_VISIBLE_TEXT_LINES)
	if line_count <= 0 {
		return {}, false
	}
	target_row := 0
	line_position := (pos.y - body.y - TEXT_PADDING) / line_height
	if line_position > 0 {
		target_row = int(math.floor(line_position))
	}
	previous_allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = previous_allocator

	for line_offset in 0 ..< line_count {
		line_index := int(first_line) + line_offset
		start, end, range_err := text_line_range(doc, rope.Line_Index(line_index))
		if !errs.ok(range_err) {
			text_render_error(range_err)
			return {}, false
		}
		read_length := min(end - start, shaping.DEFAULT_VISIBLE_BYTES + shaping.VISIBLE_LOOKAHEAD_BYTES)
		line_bytes, read_err := rope.tree_read_all(&doc.tree, {start, start + read_length}, context.temp_allocator)
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
		measurement: shaping.Measurement
		visible, shape_err := product_shape_visible(string(expansion.text[:]), &measurement, pixel_size)
		if !errs.ok(shape_err) {
			text_render_error(shape_err)
			return {}, false
		}
		defer shaping.destroy(&visible.text)

		visible_width := max(1, body.width - 2 * TEXT_PADDING)
		content_width := f32(visible.text.total_advance) / (64 * state.dpi.scale)
		horizontal := f32(0)
		if wrap_mode == .Truncate && horizontal_offset != nil {
			if math.is_nan(horizontal_offset^) || math.is_inf(horizontal_offset^) {
				horizontal_offset^ = 0
			}
			horizontal_offset^ = clamp(horizontal_offset^, 0, MAX_HORIZONTAL_SCROLL_OFFSET)
			horizontal = horizontal_offset^
		}
		rows: [dynamic]shaping.Wrap_Row
		if wrap_mode == .Soft {
			rows_err: errs.Error
			rows, rows_err = shaping.wrap_rows(visible.text, visible_width, state.dpi.scale, context.temp_allocator)
			if !errs.ok(rows_err) {
				text_render_error(rows_err)
				return {}, false
			}
		} else {
			rows = make([dynamic]shaping.Wrap_Row, context.temp_allocator)
			append(&rows, shaping.Wrap_Row{start = 0, end = content_width})
		}
		defer delete(rows)
		if target_row < len(rows) || line_offset == line_count - 1 {
			row := rows[min(target_row, len(rows) - 1)]
			hit, hit_ok := shaping.hit_test_wrap_row(visible.text, pos.x - body.x + horizontal + row.start, row, state.dpi.scale)
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
		target_row -= len(rows)
	}
	return {}, false
}
