// Rendering (M01.06): the basic column/tag/body rectangles.
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

// QUAD_VERTEX_COUNT: two rectangles x two triangles x three vertices.
QUAD_VERTEX_COUNT :: 12

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
		size = QUAD_VERTEX_COUNT * size_of(Vertex),
		label = "hammer-quad-buffer",
	})
}

// render_frame draws the current window state: the tag strip and the
// body area in the configured theme colors (M01.06). Called every
// frame inside the render pass. The window clear color is the body
// background, so the border padding between the rectangles and the
// window edges reads as body color.
render_frame :: proc() {
	width, height := services.window.framebuffer_size(services.user)
	phys := coords.Physical_Size{f32(width), f32(height)}
	if phys.width <= 0 || phys.height <= 0 {
		return
	}
	logical_size, err := coords.to_logical_size(phys, state.scale)
	if !errs.ok(err) {
		errs.destroy(&err)
		logical_size = coords.Logical_Size{phys.width, phys.height}
	}

	// Tag strip height: the configured font point size through the
	// §9.6 chain, plus one pad above and below (M05 replaces this
	// with real glyph metrics).
	font_px := coords.points_to_logical_px(cfg.Font_Size_Points)
	pad := f32(2)
	win, lerr := layout.window(logical_size, font_px + 2 * pad, pad)
	if !errs.ok(lerr) {
		errs.destroy(&lerr)
		return
	}

	verts: [QUAD_VERTEX_COUNT]Vertex
	quad_vertices(verts[0:6], win.tag, cfg.Theme.Tag_Bg, phys)
	quad_vertices(verts[6:12], win.body, cfg.Theme.Body_Bg, phys)
	sg.write_buffer_transient({
		src = {data = {ptr = raw_data(verts[:]), size = size_of(verts)}},
		dst = {buffer = render_vertex_buffer, offset = 0},
		size = size_of(verts),
	})
	bindings := sg.Bindings{vertex_buffers = {0 = render_vertex_buffer}}
	sg.apply_pipeline(render_pipeline)
	sg.apply_bindings(bindings)
	sg.draw(0, 6, 1)
	sg.draw(6, 6, 1)

	when ODIN_OS == .Linux {
		render_probe_maybe(win, phys)
	}
}

// quad_vertices fills `verts[0:6]` with the two triangles of the
// logical rectangle `r` mapped to clip coordinates. Logical y=0 is
// the top edge; GL clip y=+1 is the top.
quad_vertices :: proc(verts: []Vertex, r: layout.Rect, color: [4]f32, fb: coords.Physical_Size) {
	x0 := 2 * r.x * state.scale / fb.width - 1
	x1 := 2 * (r.x + r.width) * state.scale / fb.width - 1
	y0 := 1 - 2 * r.y * state.scale / fb.height
	y1 := 1 - 2 * (r.y + r.height) * state.scale / fb.height
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
		// A fixed point 30 logical px below the top edge: inside the
		// default 12pt tag strip (height 20) it is body color, but a
		// larger configured font (21pt -> tag height 32) paints tag
		// color there — proving font-size settings visibly change
		// the layout after rebuild.
		below_tag := probe_pixel(coords.Logical_Point{fb.width / (2 * state.scale), 30}, fb)
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
		xi := i32(int(p.x * state.scale))
		yi := i32(int(fb.height) - 1 - int(p.y * state.scale))
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
