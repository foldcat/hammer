#+build windows

package glyphcache

import "core:sys/windows"

import errs "../../core/errs"
import dw "../directwrite"

MAX_NATIVE_BITMAP_SIDE :: 4096

native_set_pixel_size :: proc(native: rawptr, requested: u32, allocator := context.allocator) -> (u32, errs.Error) {
	if native == nil || requested == 0 {
		return 0, errs.new(.Invalid_Input, "DirectWrite sizing requires a face and positive pixel size", allocator = allocator)
	}
	if requested > MAX_PIXEL_SIZE {
		return 0, errs.new(.Resource_Limit, "DirectWrite pixel size exceeds the glyph budget", allocator = allocator)
	}
	return requested, {}
}

native_rasterize :: proc(user: rawptr, key: Key, allocator := context.allocator) -> (Rasterized, errs.Error) {
	if user == nil {
		return {}, errs.new(.Invalid_Input, "DirectWrite rasterization requires a face", allocator = allocator)
	}
	if key.render_mode != .Normal {
		return {}, errs.new(.Unsupported, "the Windows adapter currently renders grayscale glyph coverage", allocator = allocator)
	}
	native := cast(^dw.Native_Face)user
	if native.face == nil || native.factory == nil || key.glyph_id > 0xffff {
		return {}, errs.new(.Invalid_Input, "invalid DirectWrite glyph rasterization input", allocator = allocator)
	}

	indices := [1]u16{u16(key.glyph_id)}
	advances := [1]f32{}
	offsets := [1]dw.Glyph_Offset{}
	run := dw.Glyph_Run{
		font_face = native.face,
		font_em_size = f32(key.pixel_size),
		glyph_count = 1,
		glyph_indices = raw_data(indices[:]),
		glyph_advances = raw_data(advances[:]),
		glyph_offsets = raw_data(offsets[:]),
	}
	analysis: ^dw.Glyph_Run_Analysis
	status := native.factory.vtable.create_glyph_run_analysis(native.factory, &run, 1, nil, .Natural_Symmetric, .Natural, 0, 0, &analysis)
	if !dw.succeeded(status) || analysis == nil {
		return {}, raster_hresult(.IO, "DirectWrite glyph analysis failed", status, allocator)
	}
	defer dw.release(analysis)
	bounds: windows.RECT
	if status = analysis.vtable.get_alpha_texture_bounds(analysis, .ClearType_3x1, &bounds); !dw.succeeded(status) {
		return {}, raster_hresult(.IO, "DirectWrite glyph bounds query failed", status, allocator)
	}
	metrics := native_metrics(native.face, key.pixel_size, u16(key.glyph_id))
	metrics.bearing_x = i32(bounds.left)
	metrics.bearing_y = -i32(bounds.top)
	width := int(bounds.right - bounds.left)
	height := int(bounds.bottom - bounds.top)
	if width < 0 || height < 0 || width > MAX_NATIVE_BITMAP_SIDE || height > MAX_NATIVE_BITMAP_SIDE {
		return {}, errs.new(.Resource_Limit, "DirectWrite glyph exceeds the native bitmap budget", allocator = allocator)
	}
	if width == 0 || height == 0 {
		return Rasterized{metrics = metrics}, {}
	}

	texture_size := width * height * 3
	texture := make([]u8, texture_size, allocator)
	defer delete(texture, allocator)
	if status = analysis.vtable.create_alpha_texture(analysis, .ClearType_3x1, &bounds, raw_data(texture), u32(texture_size)); !dw.succeeded(status) {
		return {}, raster_hresult(.IO, "DirectWrite alpha texture creation failed", status, allocator)
	}
	pixels := make([]u8, width * height, allocator)
	for index in 0 ..< width * height {
		red := int(texture[index * 3])
		green := int(texture[index * 3 + 1])
		blue := int(texture[index * 3 + 2])
		pixels[index] = u8((red + green + blue + 1) / 3)
	}
	return Rasterized{
		width = width,
		height = height,
		pitch = width,
		pixels = pixels,
		metrics = metrics,
		owned = true,
	}, {}
}

native_metrics :: proc(face: ^dw.Font_Face, pixel_size: u32, glyph_id: u16) -> Metrics {
	metrics: dw.Font_Metrics
	face.vtable.get_metrics(face, &metrics)
	if metrics.design_units_per_em == 0 {
		return {}
	}
	indices := [1]u16{glyph_id}
	glyphs := [1]dw.Glyph_Metrics{}
	if !dw.succeeded(face.vtable.get_design_glyph_metrics(face, raw_data(indices[:]), 1, raw_data(glyphs[:]), false)) {
		return {}
	}
	return Metrics{advance_x = i32((i64(glyphs[0].advance_width) * i64(pixel_size) * 64 + i64(metrics.design_units_per_em) / 2) / i64(metrics.design_units_per_em))}
}

native_char_index :: proc(native: rawptr, codepoint: rune, allocator := context.allocator) -> (u32, errs.Error) {
	if native == nil || codepoint < 0 || codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff {
		return 0, errs.new(.Invalid_Input, "DirectWrite glyph lookup requires a face and Unicode scalar", allocator = allocator)
	}
	selected := cast(^dw.Native_Face)native
	points := [1]u32{u32(codepoint)}
	indices := [1]u16{}
	status := selected.face.vtable.get_glyph_indices(selected.face, raw_data(points[:]), 1, raw_data(indices[:]))
	if !dw.succeeded(status) {
		return 0, raster_hresult(.IO, "DirectWrite glyph lookup failed", status, allocator)
	}
	return u32(indices[0]), {}
}

raster_hresult :: proc(kind: errs.Kind, message: string, status: windows.HRESULT, allocator := context.allocator) -> errs.Error {
	return errs.newf(kind, "%s (HRESULT %d)", message, i32(status), allocator = allocator)
}
