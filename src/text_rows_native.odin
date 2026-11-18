#+build linux, windows

package main

import config "core/config"
import errs "core/errs"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"
import fonts "text/fonts"
import glyphcache "text/glyphcache"
import shaping "text/shaping"

text_visual_row_count :: proc(doc: ^txn.Doc, line_index: rope.Line_Index, body: layout.Rect, wrap_mode: config.Wrap_Mode) -> (int, bool) {
	if doc == nil || body.width <= 0 || line_index < 0 || line_index >= rope.Line_Index(rope.tree_line_count(&doc.tree)) {
		return 0, false
	}
	selected := fonts.face(&font_set, .Body)
	if selected == nil {
		return 0, false
	}
	pixel_size, size_ok := glyph_pixel_size(state.dpi.scale)
	if !size_ok {
		return 0, false
	}
	if _, size_err := glyphcache.native_set_pixel_size(selected.native, pixel_size); !errs.ok(size_err) {
		text_render_error(size_err)
		return 0, false
	}
	start, end, range_err := text_line_range(doc, line_index)
	if !errs.ok(range_err) {
		text_render_error(range_err)
		return 0, false
	}
	read_length := min(end - start, shaping.DEFAULT_VISIBLE_BYTES + shaping.VISIBLE_LOOKAHEAD_BYTES)
	line_bytes, read_err := rope.tree_read_all(&doc.tree, {start, start + read_length}, context.temp_allocator)
	if !errs.ok(read_err) {
		text_render_error(read_err)
		return 0, false
	}
	expansion, tab_err := shaping.expand_tabs(string(line_bytes), shaping.DEFAULT_TAB_WIDTH, context.temp_allocator)
	if !errs.ok(tab_err) {
		text_render_error(tab_err)
		return 0, false
	}
	previous_allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = previous_allocator
	measurement: shaping.Measurement
	visible, shape_err := product_shape_visible(string(expansion.text[:]), &measurement, pixel_size)
	if !errs.ok(shape_err) {
		text_render_error(shape_err)
		return 0, false
	}
	defer shaping.destroy(&visible.text)
	if wrap_mode == .Truncate {
		return 1, true
	}
	rows, rows_err := shaping.wrap_rows(visible.text, max(1, body.width - 2 * TEXT_PADDING), state.dpi.scale, context.temp_allocator)
	if !errs.ok(rows_err) {
		text_render_error(rows_err)
		return 0, false
	}
	defer delete(rows)
	return len(rows), true
}
