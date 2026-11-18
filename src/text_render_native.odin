#+build linux, windows

package main

import "core:log"
import "core:math"

import sg "sokol:gfx"

import config "core/config"
import coords "core/coords"
import errs "core/errs"
import "core/ime"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"
import fonts "text/fonts"
import glyphcache "text/glyphcache"
import shaping "text/shaping"

TEXT_GLYPH_VS :: `#version 410
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 texcoord;
layout(location = 2) in vec4 color0;
layout(location = 3) in float native_color;
layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out float color_mode;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = texcoord;
    color = color0;
    color_mode = native_color;
}
`

TEXT_GLYPH_FS :: `#version 410
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 2) in float color_mode;
layout(location = 0) out vec4 frag_color;
uniform sampler2D glyph_tex;
void main() {
    vec4 texel = texture(glyph_tex, uv);
    if (color_mode > 0.5) {
        frag_color = texel;
    } else {
        float alpha = color.a * texel.r;
        frag_color = vec4(color.rgb * alpha, alpha);
    }
}
`

Glyph_Vertex :: struct {
	pos:        [2]f32,
	uv:         [2]f32,
	color:      [4]f32,
	color_mode: f32,
}

Glyph_Draw :: struct {
	page:  int,
	start: int,
	count: int,
	body:  layout.Rect,
}

MAX_TEXT_GLYPHS_PER_FRAME :: 2048
MAX_TEXT_QUADS_PER_FRAME :: MAX_QUADS_PER_DRAW - 2
MAX_VISIBLE_TEXT_LINES :: 4096
TEXT_PADDING :: f32(4)

text_shader: sg.Shader
text_pipeline: sg.Pipeline
text_vertex_buffer: sg.Buffer
text_sampler: sg.Sampler
text_vertices: [dynamic]Glyph_Vertex
text_draws: [dynamic]Glyph_Draw
text_draw_body: layout.Rect
text_render_error_logged := false

text_render_setup :: proc() {
	text_shader = sg.make_shader({
		vertex_func = {source = cstring(TEXT_GLYPH_VS)},
		fragment_func = {source = cstring(TEXT_GLYPH_FS)},
		attrs = {
			0 = {glsl_name = "position"},
			1 = {glsl_name = "texcoord"},
			2 = {glsl_name = "color0"},
			3 = {glsl_name = "native_color"},
		},
		views = {0 = {texture = {stage = .FRAGMENT, image_type = ._2D, sample_type = .FLOAT}}},
		samplers = {0 = {stage = .FRAGMENT, sampler_type = .FILTERING}},
		texture_sampler_pairs = {0 = {stage = .FRAGMENT, view_slot = 0, sampler_slot = 0, glsl_name = "glyph_tex"}},
		label = "hammer-glyph-shader",
	})
	if sg.query_shader_state(text_shader) != .VALID {
		log.error("render: glyph shader failed to compile; text rendering disabled")
		text_render_destroy()
		return
	}
	text_pipeline = sg.make_pipeline({
		shader = text_shader,
		layout = {attrs = {
			0 = {format = .FLOAT2},
			1 = {format = .FLOAT2},
			2 = {format = .FLOAT4},
			3 = {format = .FLOAT},
		}},
		colors = {0 = {blend = {
			enabled = true,
			src_factor_rgb = .ONE,
			dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
			src_factor_alpha = .ONE,
			dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		}}},
		primitive_type = .TRIANGLES,
		label = "hammer-glyph-pipeline",
	})
	if sg.query_pipeline_state(text_pipeline) != .VALID {
		log.error("render: glyph pipeline creation failed; text rendering disabled")
		text_render_destroy()
		return
	}
	text_vertex_buffer = sg.make_buffer({
		usage = {vertex_buffer = true, write_transient = true},
		size = MAX_TEXT_GLYPHS_PER_FRAME * 6 * size_of(Glyph_Vertex),
		label = "hammer-glyph-buffer",
	})
	text_sampler = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
		label = "hammer-glyph-sampler",
	})
}

text_render_destroy :: proc() {
	if text_sampler.id != 0 {
		sg.destroy_sampler(text_sampler)
	}
	if text_vertex_buffer.id != 0 {
		sg.destroy_buffer(text_vertex_buffer)
	}
	if text_pipeline.id != 0 {
		sg.destroy_pipeline(text_pipeline)
	}
	if text_shader.id != 0 {
		sg.destroy_shader(text_shader)
	}
	text_shader = {}
	text_pipeline = {}
	text_vertex_buffer = {}
	text_sampler = {}
}

text_render_begin :: proc() {
	text_vertices = make([dynamic]Glyph_Vertex, context.temp_allocator)
	text_draws = make([dynamic]Glyph_Draw, context.temp_allocator)
}

text_render_document :: proc(win: layout.Window, doc: ^txn.Doc, selection: txn.Selection, first_line: rope.Line_Index, first_row: int, active: bool, line_height_override: f32, wrap_mode: config.Wrap_Mode, horizontal_offset: ^f32, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {
	if doc == nil || text_pipeline.id == 0 || text_vertex_buffer.id == 0 || !glyph_cache_ready || win.body.width <= 0 || win.body.height <= 0 || first_line < 0 || first_row < 0 {
		return
	}
	selected := fonts.face(&font_set, .Body)
	if selected == nil {
		return
	}
	pixel_size, size_ok := glyph_pixel_size(state.dpi.scale)
	if !size_ok {
		return
	}
	if _, size_err := glyphcache.native_set_pixel_size(selected.native, pixel_size); !errs.ok(size_err) {
		text_render_error(size_err)
		return
	}

	font_logical := coords.points_to_logical_px(state.dpi.points)
	line_height := font_logical * cfg.Line_Height
	if line_height_override > 0 {
		line_height = line_height_override
	}
	if line_height <= 0 {
		return
	}
	ascent := f32(fonts.native_ascender(selected.native, pixel_size)) / 64
	descent := f32(fonts.native_descender(selected.native, pixel_size)) / 64
	byte_count := rope.tree_byte_count(&doc.tree)
	bounded_selection := selection
	bounded_selection.anchor = clamp(bounded_selection.anchor, 0, byte_count)
	bounded_selection.active = clamp(bounded_selection.active, 0, byte_count)
	caret_line, line_err := rope.tree_byte_to_line(&doc.tree, bounded_selection.active)
	if !errs.ok(line_err) {
		text_render_error(line_err)
		return
	}
	preedit := ime.Snapshot{}
	if active {
		preedit = ime.snapshot(&state.preedit)
	}
	line_count := min(max(0, rope.tree_line_count(&doc.tree) - int(first_line)), MAX_VISIBLE_TEXT_LINES)
	max_rows := int(win.body.height / line_height) + 1
	visual_row := 0
	text_draw_body = win.body
	for visible_index in 0 ..< line_count {
		if visual_row >= max_rows {
			break
		}
		line_index := int(first_line) + visible_index
		line_top := win.body.y + TEXT_PADDING + f32(visual_row) * line_height
		baseline_padding := TEXT_PADDING
		if line_height_override > 0 {
			line_top = win.body.y + f32(visual_row) * line_height
			text_height := (ascent + descent) / state.dpi.scale
			baseline_padding = max(0, (line_height - text_height) / 2)
		}
		baseline := (line_top + baseline_padding) * state.dpi.scale + ascent
		skip_rows := 0
		if visible_index == 0 {
			skip_rows = first_row
		}
		consumed := text_render_line(
			doc,
			rope.Line_Index(line_index),
			caret_line,
			bounded_selection,
			active,
			preedit,
			pixel_size,
			win.body,
			line_top,
			baseline,
			line_height,
			wrap_mode,
			horizontal_offset,
			skip_rows,
			fb,
			quads,
		)
		visual_row += max(1, consumed)
	}
}

text_render_draw :: proc(fb: coords.Physical_Size) {
	if len(text_vertices) == 0 {
		return
	}
	if err := glyph_atlas_sync(&glyph_atlas, &glyph_cache); !errs.ok(err) {
		text_render_error(err)
		return
	}
	sg.write_buffer_transient({
		src = {data = {ptr = raw_data(text_vertices[:]), size = len(text_vertices) * size_of(Glyph_Vertex)}},
		dst = {buffer = text_vertex_buffer},
		size = len(text_vertices) * size_of(Glyph_Vertex),
	})
	defer sg.apply_scissor_rectf(0, 0, fb.width, fb.height, false)
	sg.apply_pipeline(text_pipeline)
	for draw in text_draws {
		if draw.page < 0 || draw.page >= len(glyph_atlas.views) || glyph_atlas.views[draw.page].id == 0 {
			continue
		}
		sg.apply_scissor_rectf(
			draw.body.x * state.dpi.scale,
			fb.height - (draw.body.y + draw.body.height) * state.dpi.scale,
			draw.body.width * state.dpi.scale,
			draw.body.height * state.dpi.scale,
			false,
		)
		sg.apply_bindings({
			vertex_buffers = {0 = text_vertex_buffer},
			views = {0 = glyph_atlas.views[draw.page]},
			samplers = {0 = text_sampler},
		})
		sg.draw(draw.start, draw.count, 1)
	}
}

text_render_line :: proc(
	doc: ^txn.Doc,
	line_index: rope.Line_Index,
	caret_line: rope.Line_Index,
	selection: txn.Selection,
	active: bool,
	preedit: ime.Snapshot,
	pixel_size: u32,
	body: layout.Rect,
	line_top: f32,
	baseline: f32,
	line_height: f32,
	wrap_mode: config.Wrap_Mode,
	horizontal_offset: ^f32,
	skip_rows: int,
	fb: coords.Physical_Size,
	quads: ^[dynamic]Vertex,
) -> int {
	start, end, range_err := text_line_range(doc, line_index)
	if !errs.ok(range_err) {
		text_render_error(range_err)
		return 0
	}
	read_length := min(end - start, shaping.DEFAULT_VISIBLE_BYTES + shaping.VISIBLE_LOOKAHEAD_BYTES)
	line_bytes, read_err := rope.tree_read_all(
		&doc.tree,
		{start, start + read_length},
		context.temp_allocator,
	)
	if !errs.ok(read_err) {
		text_render_error(read_err)
		return 0
	}

	expansion, tab_err := shaping.expand_tabs(string(line_bytes), shaping.DEFAULT_TAB_WIDTH, context.temp_allocator)
	if !errs.ok(tab_err) {
		text_render_error(tab_err)
		return 0
	}
	composing := active && preedit.active && caret_line == line_index &&
		selection.active >= start && selection.active <= start + len(line_bytes)
	display := string(expansion.text[:])
	caret_offset := 0
	if caret_line == line_index {
		mapped, mapped_ok := shaping.tab_display_offset(expansion, selection.active - start)
		if !mapped_ok {
			return 0
		}
		caret_offset = mapped
	}
	preedit_start := 0
	preedit_end := 0
	if composing {
		preedit_start = caret_offset
		preedit_end = caret_offset + len(preedit.text)
		composed := make([]byte, len(expansion.text) + len(preedit.text), context.temp_allocator)
		copy(composed, expansion.text[:caret_offset])
		copy(composed[caret_offset:], preedit.text)
		copy(composed[preedit_end:], expansion.text[caret_offset:])
		display = string(composed)
		caret_offset += preedit_caret_byte(preedit.text, preedit.caret)
	}

	previous_allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = previous_allocator
	measurement: shaping.Measurement
	visible, shape_err := product_shape_visible(display, &measurement, pixel_size)
	if !errs.ok(shape_err) {
		text_render_error(shape_err)
		return 0
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
	} else if horizontal_offset != nil {
		horizontal_offset^ = 0
	}
	rows: [dynamic]shaping.Wrap_Row
	if wrap_mode == .Soft {
		rows_err: errs.Error
		rows, rows_err = shaping.wrap_rows(visible.text, visible_width, state.dpi.scale, context.temp_allocator)
		if !errs.ok(rows_err) {
			text_render_error(rows_err)
			return 0
		}
	} else {
		rows = make([dynamic]shaping.Wrap_Row, context.temp_allocator)
		append(&rows, shaping.Wrap_Row{start = 0, end = content_width})
	}
	defer delete(rows)

	font_storage: [shaping.MAX_FONTS]shaping.Font
	font_list := product_shaping_fonts(&font_storage)
	for row, row_index in rows {
		if row_index < skip_rows {
			continue
		}
		visible_index := row_index - skip_rows
		row_top := line_top + f32(visible_index) * line_height
		row_baseline := baseline + f32(visible_index) * line_height * state.dpi.scale
		x_offset := -horizontal - row.start
		if !composing {
			text_render_selection(visible.text, expansion, selection, start, end, body, row_top, line_height, row, x_offset, fb, quads)
		}
		text_collect_glyphs(visible.text, font_list, body.x * state.dpi.scale, row_baseline, row, x_offset, fb)

		if composing && preedit_start < preedit_end && preedit_start <= visible.end {
			preedit_end = min(preedit_end, visible.end)
			spans, spans_err := shaping.selection_spans(visible.text, preedit_start, preedit_end, state.dpi.scale, context.temp_allocator)
			if errs.ok(spans_err) {
				for span in spans {
					span_start := max(span.start, row.start)
					span_end := min(span.end, row.end)
					if span_start < span_end {
						text_append_quad(quads, body.x + x_offset + span_start, row_top + line_height - 1, span_end - span_start, max(1 / state.dpi.scale, 1), cfg.Theme.Caret, fb)
					}
				}
			} else {
				text_render_error(spans_err)
			}
		}

		if active && caret_line == line_index && caret_offset >= 0 && caret_offset <= visible.end {
			edge := shaping.Edge.Leading
			if selection.affinity == .Right {
				edge = .Trailing
			}
			if caret_x, ok := shaping.caret_position(visible.text, caret_offset, edge, state.dpi.scale); ok {
				if caret_x >= row.start && (caret_x < row.end || row_index == len(rows) - 1 && caret_x <= row.end) {
					text_append_quad(quads, body.x + x_offset + caret_x, row_top, max(1 / state.dpi.scale, 1), line_height, cfg.Theme.Caret, fb)
				}
			}
		}
		if row_index == len(rows) - 1 && (!visible.done || end - start > len(line_bytes) || wrap_mode == .Truncate && content_width > visible_width) {
			text_append_quad(quads, body.x + body.width - TEXT_PADDING, row_top, TEXT_PADDING, line_height, cfg.Theme.Git_Modified, fb)
		}
	}
	return max(0, len(rows) - skip_rows)
}

text_line_range :: proc(doc: ^txn.Doc, line_index: rope.Line_Index) -> (int, int, errs.Error) {
	start, start_err := rope.tree_line_start(&doc.tree, line_index)
	if !errs.ok(start_err) {
		return 0, 0, start_err
	}
	end, end_err := rope.tree_line_end(&doc.tree, line_index)
	if !errs.ok(end_err) {
		return 0, 0, end_err
	}
	if end > start {
		tail_start := max(start, end - 2)
		tail: [2]u8
		n, read_err := rope.tree_read(&doc.tree, {tail_start, end}, tail[:end - tail_start])
		if !errs.ok(read_err) {
			return 0, 0, read_err
		}
		if n > 0 && tail[n - 1] == '\n' {
			end -= 1
			if n > 1 && tail[n - 2] == '\r' {
				end -= 1
			}
		} else if n > 0 && tail[n - 1] == '\r' {
			end -= 1
		}
	}
	return start, end, {}
}

preedit_caret_byte :: proc(text: string, scalar_caret: int) -> int {
	if scalar_caret <= 0 {
		return 0
	}
	index := 0
	for _, byte_offset in text {
		if index == scalar_caret {
			return byte_offset
		}
		index += 1
	}
	return len(text)
}

text_render_selection :: proc(
	text: shaping.Text,
	expansion: shaping.Tab_Expansion,
	selection: txn.Selection,
	line_start, line_end: int,
	body: layout.Rect,
	line_top, line_height: f32,
	row: shaping.Wrap_Row,
	x_offset: f32,
	fb: coords.Physical_Size,
	quads: ^[dynamic]Vertex,
) {
	selection_start := min(selection.anchor, selection.active)
	selection_end := max(selection.anchor, selection.active)
	source_start := max(selection_start, line_start)
	source_end := min(selection_end, line_end)
	if source_start >= source_end {
		return
	}
	start, start_ok := shaping.tab_display_offset(expansion, source_start - line_start)
	end, end_ok := shaping.tab_display_offset(expansion, source_end - line_start)
	if !start_ok || !end_ok {
		return
	}
	start = min(start, measurement_end(text))
	end = min(end, measurement_end(text))
	if start >= end {
		return
	}
	spans, err := shaping.selection_spans(
		text,
		start,
		end,
		state.dpi.scale,
		context.temp_allocator,
	)
	if !errs.ok(err) {
		text_render_error(err)
		return
	}
	for span in spans {
		span_start := max(span.start, row.start)
		span_end := min(span.end, row.end)
		if span_start < span_end {
			text_append_quad(quads, body.x + x_offset + span_start, line_top, span_end - span_start, line_height, cfg.Theme.Selection_Bg, fb)
		}
	}
}

measurement_end :: proc(text: shaping.Text) -> int {
	end := 0
	for run in text.runs {
		end = max(end, run.source_end)
	}
	return end
}

text_collect_glyphs :: proc(
	text: shaping.Text,
	font_list: []shaping.Font,
	origin_x, baseline: f32,
	row: shaping.Wrap_Row,
	x_offset: f32,
	fb: coords.Physical_Size,
) {
	for run in text.runs {
		native := text_native_font(font_list, run.font_id)
		if native == nil {
			continue
		}
		for glyph in run.glyphs {
			if len(text_vertices) / 6 >= MAX_TEXT_GLYPHS_PER_FRAME {
				return
			}
			glyph_x := f32(glyph.x) / (64 * state.dpi.scale)
			if row.end > row.start && (glyph_x < row.start || glyph_x >= row.end) {
				continue
			}
			entry, err := glyphcache.get(
				&glyph_cache,
				shaping.cache_key(run, glyph),
				glyphcache.native_rasterize,
				native,
			)
			if !errs.ok(err) {
				text_render_error(err)
				continue
			}
			if entry.page < 0 {
				continue
			}
			x := origin_x + x_offset * state.dpi.scale + f32(glyph.x) / 64 + f32(entry.metrics.bearing_x)
			y := baseline - f32(glyph.y) / 64 - f32(entry.metrics.bearing_y)
			if x + f32(entry.rect.width) < 0 || y + f32(entry.rect.height) < 0 || x >= fb.width || y >= fb.height {
				continue
			}
			if len(text_draws) == 0 || text_draws[len(text_draws) - 1].page != entry.page ||
				text_draws[len(text_draws) - 1].body != text_draw_body {
				append(&text_draws, Glyph_Draw{page = entry.page, start = len(text_vertices), body = text_draw_body})
			}
			text_append_glyph(x, y, entry, fb)
			text_draws[len(text_draws) - 1].count += 6
		}
	}
}

text_native_font :: proc(font_list: []shaping.Font, font_id: u64) -> rawptr {
	for font in font_list {
		if font.font_id == font_id {
			return font.native
		}
	}
	return nil
}

text_append_glyph :: proc(x, y: f32, entry: glyphcache.Entry, fb: coords.Physical_Size) {
	page := glyph_cache.pages[entry.page]
	x0 := 2 * x / fb.width - 1
	x1 := 2 * (x + f32(entry.rect.width)) / fb.width - 1
	y0 := 1 - 2 * y / fb.height
	y1 := 1 - 2 * (y + f32(entry.rect.height)) / fb.height
	u0 := f32(entry.rect.x) / f32(page.width)
	u1 := f32(entry.rect.x + entry.rect.width) / f32(page.width)
	v0 := f32(entry.rect.y) / f32(page.height)
	v1 := f32(entry.rect.y + entry.rect.height) / f32(page.height)
	color := cfg.Theme.Body_Fg
	color_mode := f32(0)
	if page.format == .RGBA {
		color_mode = 1
	}
	append(&text_vertices,
		Glyph_Vertex{{x0, y1}, {u0, v1}, color, color_mode},
		Glyph_Vertex{{x1, y1}, {u1, v1}, color, color_mode},
		Glyph_Vertex{{x1, y0}, {u1, v0}, color, color_mode},
		Glyph_Vertex{{x0, y1}, {u0, v1}, color, color_mode},
		Glyph_Vertex{{x1, y0}, {u1, v0}, color, color_mode},
		Glyph_Vertex{{x0, y0}, {u0, v0}, color, color_mode},
	)
}

text_append_quad :: proc(
	quads: ^[dynamic]Vertex,
	x, y, width, height: f32,
	color: [4]f32,
	fb: coords.Physical_Size,
) {
	if len(quads) >= MAX_TEXT_QUADS_PER_FRAME * 6 || width <= 0 || height <= 0 || fb.width <= 0 || fb.height <= 0 {
		return
	}
	start := len(quads)
	resize(quads, start + 6)
	quad_vertices(quads[start:], {x, y, width, height}, color, fb)
}

text_render_error :: proc(err: errs.Error) {
	if !text_render_error_logged {
		log.warnf("render-text: %v", errs.describe(err))
		text_render_error_logged = true
	}
	owned := err
	errs.destroy(&owned)
}
