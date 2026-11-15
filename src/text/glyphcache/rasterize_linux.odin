package glyphcache

import errs "../../core/errs"
import ft "../freetype"

native_rasterize :: proc(user: rawptr, key: Key, allocator := context.allocator) -> (Rasterized, errs.Error) {
	if user == nil {
		return {}, errs.new(.Invalid_Input, "FreeType rasterization requires a face", allocator = allocator)
	}
	if key.render_mode != .Normal {
		return {}, errs.new(.Unsupported, "only normal FreeType coverage is currently supported", allocator = allocator)
	}
	face := ft.Face(user)
	if err := ft.FT_Set_Pixel_Sizes(face, 0, key.pixel_size); err != 0 {
		return {}, errs.newf(.IO, "FreeType pixel sizing failed: %d", err, allocator = allocator)
	}
	if err := ft.FT_Load_Glyph(face, key.glyph_id, ft.LOAD_DEFAULT | ft.LOAD_RENDER); err != 0 {
		return {}, errs.newf(.IO, "FreeType glyph loading failed: %d", err, allocator = allocator)
	}
	if face.glyph == nil {
		return {}, errs.new(.Internal, "FreeType returned no glyph slot", allocator = allocator)
	}
	bitmap := face.glyph.bitmap
	if bitmap.pixel_mode != u8(ft.Pixel_Mode.Gray) {
		return {}, errs.new(.Unsupported, "FreeType returned a non-gray coverage bitmap", allocator = allocator)
	}
	if bitmap.width == 0 || bitmap.rows == 0 {
		return Rasterized{metrics = native_metrics(face)}, errs.Error{}
	}
	if bitmap.pitch <= 0 || bitmap.buffer == nil {
		return {}, errs.new(.Invalid_Input, "FreeType returned an invalid glyph bitmap", allocator = allocator)
	}
	return Rasterized{
		width = int(bitmap.width),
		height = int(bitmap.rows),
		pitch = int(bitmap.pitch),
		pixels = bitmap.buffer[:int(bitmap.pitch) * int(bitmap.rows)],
		metrics = native_metrics(face),
	}, errs.Error{}
}

native_char_index :: proc(face: rawptr, codepoint: rune, allocator := context.allocator) -> (u32, errs.Error) {
	if face == nil {
		return 0, errs.new(.Invalid_Input, "FreeType glyph lookup requires a face", allocator = allocator)
	}
	return ft.FT_Get_Char_Index(ft.Face(face), ft.ULong(codepoint)), errs.Error{}
}

native_metrics :: proc(face: ft.Face) -> Metrics {
	return Metrics{
		advance_x = i32(face.glyph.metrics.hori_advance),
		advance_y = i32(face.glyph.metrics.vert_advance),
		bearing_x = i32(face.glyph.bitmap_left),
		bearing_y = i32(face.glyph.bitmap_top),
	}
}
