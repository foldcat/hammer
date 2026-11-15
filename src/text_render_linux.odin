#+build linux

package main

import "core:log"

import sg "sokol:gfx"

import coords "core/coords"
import errs "core/errs"
import "core/ime"
import layout "core/layout"
import rope "core/rope"
import fonts "text/fonts"
import ft "text/freetype"
import glyphcache "text/glyphcache"
import shaping "text/shaping"

TEXT_GLYPH_VS :: `#version 410
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 texcoord;
layout(location = 2) in vec4 color0;
layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = texcoord;
    color = color0;
}
`

TEXT_GLYPH_FS :: `#version 410
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 0) out vec4 frag_color;
uniform sampler2D glyph_tex;
void main() {
    float coverage = texture(glyph_tex, uv).r;
    frag_color = vec4(color.rgb, color.a * coverage);
}
`

Glyph_Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

Glyph_Draw :: struct {
	page:  int,
	start: int,
	count: int,
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
text_render_error_logged := false

text_render_setup :: proc() {
	text_shader = sg.make_shader({
		vertex_func = {source = cstring(TEXT_GLYPH_VS)},
		fragment_func = {source = cstring(TEXT_GLYPH_FS)},
		attrs = {
			0 = {glsl_name = "position"},
			1 = {glsl_name = "texcoord"},
			2 = {glsl_name = "color0"},
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
		}},
		colors = {0 = {blend = {
			enabled = true,
			src_factor_rgb = .SRC_ALPHA,
			dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
			src_factor_alpha = .SRC_ALPHA,
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

text_render_document :: proc(win: layout.Window, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {
	text_vertices = make([dynamic]Glyph_Vertex, context.temp_allocator)
	text_draws = make([dynamic]Glyph_Draw, context.temp_allocator)
	if text_pipeline.id == 0 || text_vertex_buffer.id == 0 || !glyph_cache_ready || win.body.width <= 0 || win.body.height <= 0 {
		return
	}
	selected := fonts.face(&font_set, .Body)
	if selected == nil {
		return
	}
	pixel_size, size_ok := glyph_pixel_size(state.dpi.scale)
	if !size_ok || ft.FT_Set_Pixel_Sizes(ft.Face(selected.native), 0, pixel_size) != 0 {
		return
	}

	font_list := [1]shaping.Font{{
		font_id = u64(fonts.Role.Body) + 1,
		face_index = selected.face_index,
		native = selected.native,
	}}
	font_logical := coords.points_to_logical_px(cfg.Font_Size_Points)
	line_height := font_logical * cfg.Line_Height
	if line_height <= 0 {
		return
	}
	ascent := f32(selected_native_ascender(selected.native)) / 64
	caret_line, line_err := rope.tree_byte_to_line(&editor.doc.tree, editor.selection.active)
	if !errs.ok(line_err) {
		text_render_error(line_err)
		return
	}
	preedit := ime.snapshot(&state.preedit)
	line_count := min(
		rope.tree_line_count(&editor.doc.tree),
		MAX_VISIBLE_TEXT_LINES,
		int(win.body.height / line_height) + 1,
	)
	for line_index in 0 ..< line_count {
		line_top := win.body.y + TEXT_PADDING + f32(line_index) * line_height
		baseline := (line_top + TEXT_PADDING) * state.dpi.scale + ascent
		text_render_line(
			rope.Line_Index(line_index),
			caret_line,
			preedit,
			font_list[:],
			pixel_size,
			win.body,
			line_top,
			baseline,
			line_height,
			fb,
			quads,
		)
	}
}

text_render_draw :: proc(body: layout.Rect, fb: coords.Physical_Size) {
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
	sg.apply_scissor_rectf(
		body.x * state.dpi.scale,
		fb.height - (body.y + body.height) * state.dpi.scale,
		body.width * state.dpi.scale,
		body.height * state.dpi.scale,
		false,
	)
	defer sg.apply_scissor_rectf(0, 0, fb.width, fb.height, false)
	sg.apply_pipeline(text_pipeline)
	for draw in text_draws {
		if draw.page < 0 || draw.page >= len(glyph_atlas.views) || glyph_atlas.views[draw.page].id == 0 {
			continue
		}
		sg.apply_bindings({
			vertex_buffers = {0 = text_vertex_buffer},
			views = {0 = glyph_atlas.views[draw.page]},
			samplers = {0 = text_sampler},
		})
		sg.draw(draw.start, draw.count, 1)
	}
}

selected_native_ascender :: proc(native: rawptr) -> i64 {
	face := ft.Face(native)
	if face.size == nil {
		return 0
	}
	return i64(face.size.metrics.ascender)
}

text_render_line :: proc(
	line_index: rope.Line_Index,
	caret_line: rope.Line_Index,
	preedit: ime.Snapshot,
	font_list: []shaping.Font,
	pixel_size: u32,
	body: layout.Rect,
	line_top: f32,
	baseline: f32,
	line_height: f32,
	fb: coords.Physical_Size,
	quads: ^[dynamic]Vertex,
) {
	start, end, range_err := text_line_range(line_index)
	if !errs.ok(range_err) {
		text_render_error(range_err)
		return
	}
	read_length := min(end - start, shaping.DEFAULT_VISIBLE_BYTES + shaping.VISIBLE_LOOKAHEAD_BYTES)
	line_bytes, read_err := rope.tree_read_all(
		&editor.doc.tree,
		{start, start + read_length},
		context.temp_allocator,
	)
	if !errs.ok(read_err) {
		text_render_error(read_err)
		return
	}

	composing := preedit.active && caret_line == line_index &&
		editor.selection.active >= start && editor.selection.active <= start + len(line_bytes)
	display := string(line_bytes)
	caret_offset := editor.selection.active - start
	preedit_start := 0
	preedit_end := 0
	if composing {
		preedit_start = caret_offset
		preedit_end = caret_offset + len(preedit.text)
		composed := make([]byte, len(line_bytes) + len(preedit.text), context.temp_allocator)
		copy(composed, line_bytes[:caret_offset])
		copy(composed[caret_offset:], preedit.text)
		copy(composed[preedit_end:], line_bytes[caret_offset:])
		display = string(composed)
		caret_offset += preedit_caret_byte(preedit.text, preedit.caret)
	}

	previous_allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = previous_allocator
	measurement: shaping.Measurement
	visible, shape_err := shaping.visible_next(
		display,
		&measurement,
		font_list,
		{pixel_size = pixel_size, ligatures = cfg.Ligatures},
		shaping.DEFAULT_VISIBLE_BYTES,
		context.temp_allocator,
	)
	if !errs.ok(shape_err) {
		text_render_error(shape_err)
		return
	}
	defer shaping.destroy(&visible.text)

	if !composing {
		text_render_selection(visible.text, start, end, body, line_top, line_height, fb, quads)
	}
	text_collect_glyphs(visible.text, font_list, body.x * state.dpi.scale, baseline, fb)

	if composing && preedit_start < preedit_end && preedit_start <= visible.end {
		preedit_end = min(preedit_end, visible.end)
		spans, spans_err := shaping.selection_spans(
			visible.text,
			preedit_start,
			preedit_end,
			state.dpi.scale,
			context.temp_allocator,
		)
		if errs.ok(spans_err) {
			for span in spans {
				text_append_quad(
					quads,
					body.x + span.start,
					line_top + line_height - 1,
					span.end - span.start,
					max(1 / state.dpi.scale, 1),
					cfg.Theme.Caret,
					fb,
				)
			}
		} else {
			text_render_error(spans_err)
		}
	}

	if caret_line == line_index && caret_offset >= 0 && caret_offset <= visible.end {
		edge := shaping.Edge.Leading
		if editor.selection.affinity == .Right {
			edge = .Trailing
		}
		if caret_x, ok := shaping.caret_position(visible.text, caret_offset, edge, state.dpi.scale); ok {
			text_append_quad(
				quads,
				body.x + caret_x,
				line_top,
				max(1 / state.dpi.scale, 1),
				line_height,
				cfg.Theme.Caret,
				fb,
			)
		}
	}

	if !visible.done || end - start > len(line_bytes) {
		text_append_quad(
			quads,
			body.x + body.width - TEXT_PADDING,
			line_top,
			TEXT_PADDING,
			line_height,
			cfg.Theme.Git_Modified,
			fb,
		)
	}
}

text_line_range :: proc(line_index: rope.Line_Index) -> (int, int, errs.Error) {
	start, start_err := rope.tree_line_start(&editor.doc.tree, line_index)
	if !errs.ok(start_err) {
		return 0, 0, start_err
	}
	end, end_err := rope.tree_line_end(&editor.doc.tree, line_index)
	if !errs.ok(end_err) {
		return 0, 0, end_err
	}
	if end > start {
		tail_start := max(start, end - 2)
		tail: [2]u8
		n, read_err := rope.tree_read(&editor.doc.tree, {tail_start, end}, tail[:end - tail_start])
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
	line_start, line_end: int,
	body: layout.Rect,
	line_top, line_height: f32,
	fb: coords.Physical_Size,
	quads: ^[dynamic]Vertex,
) {
	selection_start := min(editor.selection.anchor, editor.selection.active)
	selection_end := max(editor.selection.anchor, editor.selection.active)
	start := max(selection_start, line_start)
	end := min(selection_end, line_end)
	if start >= end {
		return
	}
	start = min(start, line_start + measurement_end(text))
	end = min(end, line_start + measurement_end(text))
	if start >= end {
		return
	}
	spans, err := shaping.selection_spans(
		text,
		start - line_start,
		end - line_start,
		state.dpi.scale,
		context.temp_allocator,
	)
	if !errs.ok(err) {
		text_render_error(err)
		return
	}
	for span in spans {
		text_append_quad(quads, body.x + span.start, line_top, span.end - span.start, line_height, cfg.Theme.Selection_Bg, fb)
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
			x := origin_x + f32(glyph.x) / 64 + f32(entry.metrics.bearing_x)
			y := baseline - f32(glyph.y) / 64 - f32(entry.metrics.bearing_y)
			if x + f32(entry.rect.width) < 0 || y + f32(entry.rect.height) < 0 || x >= fb.width || y >= fb.height {
				continue
			}
			if len(text_draws) == 0 || text_draws[len(text_draws) - 1].page != entry.page {
				append(&text_draws, Glyph_Draw{page = entry.page, start = len(text_vertices)})
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
	append(&text_vertices,
		Glyph_Vertex{{x0, y1}, {u0, v1}, color},
		Glyph_Vertex{{x1, y1}, {u1, v1}, color},
		Glyph_Vertex{{x1, y0}, {u1, v0}, color},
		Glyph_Vertex{{x0, y1}, {u0, v1}, color},
		Glyph_Vertex{{x1, y0}, {u1, v0}, color},
		Glyph_Vertex{{x0, y0}, {u0, v0}, color},
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
