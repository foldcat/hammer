// Rendering (M01.06, M05.06, M06.09–M06.10, M07.01–M07.02): workspace rectangles and per-view document text.
//
// This is the application-layer renderer (package main): it draws the
// logical window geometry from `core/layout` with sokol_gfx,
// converting logical units to framebuffer pixels with `core/coords` —
// DPI is applied exactly once, at that boundary (SPECS.md §9.6). The
// core packages never see sokol (M01 acceptance).
//
// The shader is a single embedded GLSL 410 colored-quad shader (the
// GL backend only today). Shader-tooling formalization (sokol-shdc,
// Metal/D3D11 variants) is the recorded M05.01 follow-up
// (docs/notes/m00-09-decisions.md); the pinned sokol_gfx revision accepts
// GLSL source directly on GL backends.
package main

import "core:log"

import sg "sokol:gfx"

import "core/errs"
import coords "core/coords"
import layout "core/layout"
import scroll "core/scroll"
import txn "core/txn"
import view "core/view"

// VS_SOURCE / FS_SOURCE: colored-quad shader (position in clip
// coordinates + per-vertex RGBA).
VS_SOURCE :: `#version 410
layout(location = 0) in vec2 position;
layout(location = 1) in vec4 color0;
layout(location = 0) out vec4 color;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    color = color0;
}
`

FS_SOURCE :: `#version 410
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = color;
}
`

// Vertex is the interleaved vertex format: clip-space position + RGBA.
Vertex :: struct {
	pos:   [2]f32,
	color: [4]f32,
}

QUAD_VERTEX_COUNT :: 12
MAX_QUADS_PER_DRAW :: 4096
SCROLLBAR_THUMB_COLOR :: [4]f32{82.0 / 255.0, 82.0 / 255.0, 82.0 / 255.0, 1}

render_pipeline: sg.Pipeline
render_vertex_buffer: sg.Buffer

// render_setup creates the shader, pipeline, and vertex buffer. Called
// once from init after sg.setup. A failed shader compile or pipeline
// creation is reported and degrades to no rendering — never a crash.
render_setup :: proc() {
	shader := sg.make_shader({
		vertex_func = {source = cstring(VS_SOURCE)},
		fragment_func = {source = cstring(FS_SOURCE)},
		attrs = {
			0 = {glsl_name = "position"},
			1 = {glsl_name = "color0"},
		},
		label = "hammer-quad-shader",
	})
	if sg.query_shader_state(shader) != .VALID {
		log.error("render: quad shader failed to compile; rendering disabled")
		return
	}
	render_pipeline = sg.make_pipeline({
		shader = shader,
		layout = {attrs = {
			0 = {format = .FLOAT2},
			1 = {format = .FLOAT4},
		}},
		primitive_type = .TRIANGLES,
		label = "hammer-quad-pipeline",
	})
	if sg.query_pipeline_state(render_pipeline) != .VALID {
		log.error("render: quad pipeline creation failed; rendering disabled")
		return
	}
	render_vertex_buffer = sg.make_buffer({
		usage = {vertex_buffer = true, write_transient = true},
		size = MAX_QUADS_PER_DRAW * 6 * size_of(Vertex),
		label = "hammer-quad-buffer",
	})
	text_render_setup()
}

render_frame :: proc() {
	geometry, phys, ok := current_layout()
	if !ok {
		return
	}

	verts := make([dynamic]Vertex, 0, context.temp_allocator)
	pad := workspace_metrics().pad
	global_tag := geometry.global_tag
	global_tag.x += pad
	global_tag.y += pad
	global_tag.width = max(0, global_tag.width - 2 * pad)
	// Keep the full tag height (matching column and window tags). Reducing it
	// by 2*pad here made the global tag strip shorter than the other tags and
	// clipped its text at the bottom.
	render_append_quad(&verts, global_tag, cfg.Theme.Tag_Bg, phys)
	text_render_begin()
	text_render_tag(global_tag, &editor.global_tag.doc, editor.global_tag.selection, editor.active_text_kind == .Global_Tag, phys, &verts)
	for column_index in 0 ..< geometry.column_count {
		column := &geometry.columns[column_index]
		render_append_quad(&verts, column.tag, cfg.Theme.Tag_Bg, phys)
		render_append_quad(&verts, column.control, cfg.Theme.Git_Modified, phys)
		column_active := editor.active_text_kind == .Column_Tag && editor.active_column == column.id
		column_tag := editor_column_tag(column.id)
		text_render_tag(tag_content_rect(column.tag, column.control), &column_tag.doc, column_tag.selection, column_active, phys, &verts)
		for window_index in 0 ..< column.window_count {
			placed := column.windows[window_index]
			render_append_quad(&verts, placed.window.tag, cfg.Theme.Tag_Bg, phys)
			render_append_quad(&verts, placed.window.body, cfg.Theme.Body_Bg, phys)
			control_color := cfg.Theme.Tag_Fg
			if placed.id == editor.active_window {
				control_color = cfg.Theme.Caret
			}
			render_append_quad(&verts, placed.control, control_color, phys)
			item, found := view.find(&editor.views, placed.id)
			if found {
				window_tag_active := editor.active_text_kind == .Window_Tag && editor.active_window == placed.id
				text_render_tag(tag_content_rect(placed.window.tag, placed.control), &item.tag.doc, item.tag.selection, window_tag_active, phys, &verts)
				body_active := editor.active_text_kind == .Body && editor.active_window == placed.id
				doc := &editor_buffer_for_view(item).doc
				track, gutter, text := editor_body_parts(item, doc, placed.window.body)
				first_line_rows := editor_normalize_view_origin(item, doc, text)
				render_append_quad(&verts, track, cfg.Theme.Tag_Bg, phys)
				thumb := scroll.thumb_rect(track, int(item.first_line), item.first_row, first_line_rows, rope_line_count(doc), editor_visible_rows(text))
				render_append_quad(&verts, thumb, SCROLLBAR_THUMB_COLOR, phys)
				if gutter.width > 0 {
					separator := gutter
					separator.x += gutter.width - 1
					separator.width = 1
					render_append_quad(&verts, separator, cfg.Theme.Tag_Bg, phys)
				}
				text_window := placed.window
				text_window.body = text
				text_render_document(text_window, gutter, item.line_numbers, doc, item.selection, item.first_line, item.first_row, body_active, 0, item.wrap_mode, &item.horizontal_offset, phys, &verts)
			}
		}
	}
	draw_quads(verts[:])
	text_render_draw(phys)

	when ODIN_OS == .Linux {
		if win, found := window_for_id(&geometry, editor.active_window); found {
			render_probe_maybe(win, phys)
		}
	}
}

workspace_metrics :: proc() -> layout.Metrics {
	font_px := coords.points_to_logical_px(state.dpi.points)
	return layout.default_metrics(font_px + 4)
}

tag_content_rect :: proc(tag, control: layout.Rect) -> layout.Rect {
	content := tag
	content.x += control.width
	content.width = max(0, content.width - control.width)
	return content
}

text_render_tag :: proc(rect: layout.Rect, doc: ^txn.Doc, selection: txn.Selection, active: bool, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {
	win := layout.Window{body = rect}
	text_render_document(win, {}, false, doc, selection, 0, 0, active, rect.height, .Truncate, nil, fb, quads)
}

current_layout :: proc() -> (layout.Geometry, coords.Physical_Size, bool) {
	width, height := services.window.framebuffer_size(services.user)
	phys := coords.Physical_Size{f32(width), f32(height)}
	if phys.width <= 0 || phys.height <= 0 {
		return {}, phys, false
	}
	logical_size, err := coords.to_logical_size(phys, state.dpi.scale)
	if !errs.ok(err) {
		errs.destroy(&err)
		logical_size = coords.Logical_Size{phys.width, phys.height}
	}

	geometry, layout_err := layout.arrange(&editor.workspace, logical_size, workspace_metrics())
	if !errs.ok(layout_err) {
		editor_report(layout_err)
		return {}, phys, false
	}
	return geometry, phys, true
}

current_window :: proc() -> (layout.Window, coords.Physical_Size, bool) {
	geometry, phys, ok := current_layout()
	if !ok {
		return {}, phys, false
	}
	win, found := window_for_id(&geometry, editor.active_window)
	return win, phys, found
}

window_for_id :: proc(geometry: ^layout.Geometry, id: layout.Window_ID) -> (layout.Window, bool) {
	for column_index in 0 ..< geometry.column_count {
		column := &geometry.columns[column_index]
		for placed in column.windows[:column.window_count] {
			if placed.id == id {
				return placed.window, true
			}
		}
	}
	return {}, false
}

editor_active_text_rect :: proc(geometry: ^layout.Geometry) -> (layout.Rect, bool) {
	switch editor.active_text_kind {
	case .Body:
		win, ok := window_for_id(geometry, editor.active_window)
		return win.body, ok
	case .Global_Tag:
		rect := geometry.global_tag
		pad := workspace_metrics().pad
		rect.x += pad
		rect.y += pad
		rect.width = max(0, rect.width - 2 * pad)
		return rect, true
	case .Column_Tag:
		index, ok := layout.find_column(&editor.workspace, editor.active_column)
		if !ok || index >= geometry.column_count {
			return {}, false
		}
		column := geometry.columns[index]
		return tag_content_rect(column.tag, column.control), true
	case .Window_Tag:
		for column_index in 0 ..< geometry.column_count {
			column := &geometry.columns[column_index]
			for placed in column.windows[:column.window_count] {
				if placed.id == editor.active_window {
					return tag_content_rect(placed.window.tag, placed.control), true
				}
			}
		}
	}
	return {}, false
}

render_append_quad :: proc(verts: ^[dynamic]Vertex, rect: layout.Rect, color: [4]f32, fb: coords.Physical_Size) {
	if rect.width <= 0 || rect.height <= 0 || len(verts) + 6 > MAX_QUADS_PER_DRAW * 6 {
		return
	}
	start := len(verts)
	resize(verts, start + 6)
	quad_vertices(verts[start:], rect, color, fb)
}

draw_quads :: proc(verts: []Vertex) {
	if len(verts) == 0 || len(verts) % 6 != 0 || len(verts) > MAX_QUADS_PER_DRAW * 6 ||
		render_pipeline.id == 0 || render_vertex_buffer.id == 0 {
		return
	}
	sg.write_buffer_transient({
		src = {data = {ptr = raw_data(verts), size = len(verts) * size_of(Vertex)}},
		dst = {buffer = render_vertex_buffer},
		size = len(verts) * size_of(Vertex),
	})
	sg.apply_pipeline(render_pipeline)
	sg.apply_bindings({vertex_buffers = {0 = render_vertex_buffer}})
	sg.draw(0, len(verts), 1)
}

// quad_vertices fills `verts[0:6]` with the two triangles of the
// logical rectangle `r` mapped to clip coordinates. Logical y=0 is
// the top edge; GL clip y=+1 is the top.
quad_vertices :: proc(verts: []Vertex, r: layout.Rect, color: [4]f32, fb: coords.Physical_Size) {
	x0 := 2 * r.x * state.dpi.scale / fb.width - 1
	x1 := 2 * (r.x + r.width) * state.dpi.scale / fb.width - 1
	y0 := 1 - 2 * r.y * state.dpi.scale / fb.height
	y1 := 1 - 2 * (r.y + r.height) * state.dpi.scale / fb.height
	bl := Vertex{{x0, y1}, color}
	br := Vertex{{x1, y1}, color}
	tr := Vertex{{x1, y0}, color}
	tl := Vertex{{x0, y0}, color}
	verts[0] = bl
	verts[1] = br
	verts[2] = tr
	verts[3] = bl
	verts[4] = tr
	verts[5] = tl
}

// ---- Render probe (HAMMER_RENDER_PROBE test hook, Linux/X11) -------
//
// Reads back single pixels from the default framebuffer with raw GL
// (the pinned sokol_gfx revision has no read-back API) and logs the
// rendered colors at three sample points. This proves headlessly that
// the theme rectangles are actually drawn — the M01 acceptance
// "configuration edits visibly change colors after rebuild" — without
// a desktop. Guarded by ODIN_OS so the Windows cross-build never
// links libGL.

when ODIN_OS == .Linux {
	foreign import gl_probe "system:GL"
	foreign gl_probe {
		glReadPixels :: proc(x, y, width, height: i32, format, type_: u32, pixels: rawptr) ---
	}

	// GL_RGBA / GL_UNSIGNED_BYTE from <GL/gl.h>; pinned as constants
	// so this file needs no C headers.
	GL_RGBA :: 0x1908
	GL_UNSIGNED_BYTE :: 0x1401

	// render_probe_maybe fires once, at the frame configured via
	// HAMMER_RENDER_PROBE, inside the render pass (the default
	// framebuffer is bound there).
	render_probe_maybe :: proc(win: layout.Window, fb: coords.Physical_Size) {
		if state.probe_frame == 0 || state.frame_count != state.probe_frame {
			return
		}
		tag := probe_pixel(rect_center(win.tag), fb)
		body := probe_pixel(rect_center(win.body), fb)
		corner := probe_pixel(coords.Logical_Point{1, 1}, fb)
		// A fixed point 30 logical px below the active window's top edge:
		// inside the default 12pt tag strip (height 20) it is body color,
		// but a larger configured font (21pt -> tag height 32) paints tag
		// color there — proving font-size settings visibly change the
		// layout after rebuild.
		below_tag := probe_pixel(coords.Logical_Point{win.frame.x + win.frame.width / 2, win.frame.y + 30}, fb)
		log.infof(
			"render-probe: tag=#%02X%02X%02X body=#%02X%02X%02X corner=#%02X%02X%02X below-tag=#%02X%02X%02X",
			tag[0],
			tag[1],
			tag[2],
			body[0],
			body[1],
			body[2],
			corner[0],
			corner[1],
			corner[2],
			below_tag[0],
			below_tag[1],
			below_tag[2],
		)
	}

	// probe_pixel reads the framebuffer pixel under a logical
	// position (GL pixel rows count from the bottom; logical y from
	// the top).
	probe_pixel :: proc(p: coords.Logical_Point, fb: coords.Physical_Size) -> [3]u8 {
		px: [4]u8
		xi := i32(int(p.x * state.dpi.scale))
		yi := i32(int(fb.height) - 1 - int(p.y * state.dpi.scale))
		if xi < 0 || yi < 0 || xi >= i32(int(fb.width)) || yi >= i32(int(fb.height)) {
			return {0, 0, 0}
		}
		glReadPixels(xi, yi, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px[0])
		return {px[0], px[1], px[2]}
	}

	// rect_center returns the logical center of a rectangle.
	rect_center :: proc(r: layout.Rect) -> coords.Logical_Point {
		return coords.Logical_Point{r.x + r.width / 2, r.y + r.height / 2}
	}
}
