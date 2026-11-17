package glyphcache

import "base:runtime"
import "core:math"
import "core:mem"

import errs "../../core/errs"
import ft "../freetype"

MAX_NATIVE_BITMAP_SIDE :: 4096

native_set_pixel_size :: proc(native: rawptr, requested: u32, allocator := context.allocator) -> (u32, errs.Error) {
	face := ft.Face(native)
	if face == nil || requested == 0 {
		return 0, errs.new(.Invalid_Input, "FreeType sizing requires a face and positive pixel size", allocator = allocator)
	}
	size_err := ft.FT_Set_Pixel_Sizes(face, 0, requested)
	if size_err == 0 {
		return requested, {}
	}
	if face.num_fixed_sizes <= 0 || face.available_sizes == nil {
		return 0, errs.newf(.IO, "FreeType pixel sizing failed: %d", size_err, allocator = allocator)
	}

	best_size := u32(0)
	best_distance := max(int)
	for index in 0 ..< int(face.num_fixed_sizes) {
		candidate := face.available_sizes[index].y_ppem / 64
		if candidate <= 0 || candidate > ft.Pos(max(u32)) {
			continue
		}
		size := u32(candidate)
		distance := abs(int(size) - int(requested))
		if distance < best_distance {
			best_distance = distance
			best_size = size
		}
	}
	if best_size == 0 {
		return 0, errs.newf(.IO, "FreeType pixel sizing failed: %d", size_err, allocator = allocator)
	}
	if err := ft.FT_Set_Pixel_Sizes(face, 0, best_size); err != 0 {
		return 0, errs.newf(.IO, "FreeType bitmap strike selection failed: %d for %d px", err, best_size, allocator = allocator)
	}
	return best_size, {}
}

native_rasterize :: proc(user: rawptr, key: Key, allocator := context.allocator) -> (Rasterized, errs.Error) {
	if user == nil {
		return {}, errs.new(.Invalid_Input, "FreeType rasterization requires a face", allocator = allocator)
	}
	if key.render_mode == .Mono {
		return {}, errs.new(.Unsupported, "only normal and color FreeType rendering are supported", allocator = allocator)
	}
	face := ft.Face(user)
	actual_size, size_err := native_set_pixel_size(face, key.pixel_size, allocator)
	if !errs.ok(size_err) {
		return {}, size_err
	}
	flags := ft.LOAD_DEFAULT | ft.LOAD_RENDER
	if key.render_mode == .Color {
		flags |= ft.LOAD_COLOR
	}
	if err := ft.FT_Load_Glyph(face, key.glyph_id, flags); err != 0 {
		return {}, errs.newf(.IO, "FreeType glyph loading failed: %d", err, allocator = allocator)
	}
	if face.glyph == nil {
		return {}, errs.new(.Internal, "FreeType returned no glyph slot", allocator = allocator)
	}
	if key.render_mode == .Color {
		return native_color_bitmap(face, key.pixel_size, actual_size, allocator)
	}

	bitmap := face.glyph.bitmap
	if bitmap.pixel_mode != u8(ft.Pixel_Mode.Gray) {
		return {}, errs.new(.Unsupported, "FreeType returned a non-gray coverage bitmap", allocator = allocator)
	}
	if bitmap.width == 0 || bitmap.rows == 0 {
		return Rasterized{metrics = native_metrics(face)}, {}
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
	}, {}
}

native_color_bitmap :: proc(face: ft.Face, requested, actual: u32, allocator: runtime.Allocator) -> (Rasterized, errs.Error) {
	bitmap := face.glyph.bitmap
	if bitmap.pixel_mode != u8(ft.Pixel_Mode.BGRA) {
		return {}, errs.new(.Unsupported, "FreeType did not return a BGRA color bitmap", allocator = allocator)
	}
	if bitmap.width > MAX_NATIVE_BITMAP_SIDE || bitmap.rows > MAX_NATIVE_BITMAP_SIDE {
		return {}, errs.new(.Resource_Limit, "color glyph exceeds the native bitmap budget", allocator = allocator)
	}
	if bitmap.width == 0 || bitmap.rows == 0 {
		return Rasterized{format = .RGBA, metrics = scaled_color_metrics(face, requested, actual)}, {}
	}
	if int(bitmap.pitch) < int(bitmap.width) * 4 || bitmap.buffer == nil {
		return {}, errs.new(.Invalid_Input, "FreeType returned an invalid BGRA bitmap", allocator = allocator)
	}

	width := scale_dimension(int(bitmap.width), requested, actual)
	height := scale_dimension(int(bitmap.rows), requested, actual)
	if width <= 0 || height <= 0 || width > MAX_NATIVE_BITMAP_SIDE || height > MAX_NATIVE_BITMAP_SIDE {
		return {}, errs.new(.Resource_Limit, "scaled color glyph exceeds the bitmap budget", allocator = allocator)
	}
	pixels, alloc_err := mem.alloc_bytes(width * height * 4, 1, allocator)
	if alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "color glyph allocation failed", allocator = allocator)
	}
	source := bitmap.buffer[:int(bitmap.pitch) * int(bitmap.rows)]
	channels := [4]int{2, 1, 0, 3}
	for y in 0 ..< height {
		source_y := (f64(y) + 0.5) * f64(bitmap.rows) / f64(height) - 0.5
		y0, y1, fy := sample_axis(source_y, int(bitmap.rows))
		for x in 0 ..< width {
			source_x := (f64(x) + 0.5) * f64(bitmap.width) / f64(width) - 0.5
			x0, x1, fx := sample_axis(source_x, int(bitmap.width))
			for input_channel, output_channel in channels {
				upper_left := color_sample(source, bitmap, x0, y0, input_channel)
				upper_right := color_sample(source, bitmap, x1, y0, input_channel)
				lower_left := color_sample(source, bitmap, x0, y1, input_channel)
				lower_right := color_sample(source, bitmap, x1, y1, input_channel)
				upper := upper_left + (upper_right - upper_left) * fx
				lower := lower_left + (lower_right - lower_left) * fx
				value := int(math.floor(upper + (lower - upper) * fy + 0.5))
				pixels[(y * width + x) * 4 + output_channel] = u8(clamp(value, 0, 255))
			}
		}
	}
	return Rasterized{
		width = width,
		height = height,
		pitch = width * 4,
		pixels = pixels,
		metrics = scaled_color_metrics(face, requested, actual),
		format = .RGBA,
		owned = true,
	}, {}
}

sample_axis :: proc(position: f64, size: int) -> (int, int, f64) {
	lower := int(math.floor(position))
	fraction := position - f64(lower)
	if lower < 0 {
		return 0, min(1, size - 1), 0
	}
	if lower >= size - 1 {
		return size - 1, size - 1, 0
	}
	return lower, lower + 1, fraction
}

color_sample :: proc(source: []u8, bitmap: ft.Bitmap, x, y, channel: int) -> f64 {
	return f64(source[y * int(bitmap.pitch) + x * 4 + channel])
}

scale_dimension :: proc(value: int, requested, actual: u32) -> int {
	return int((i64(value) * i64(requested) + i64(actual) / 2) / i64(actual))
}

scale_metric :: proc(value: ft.Pos, requested, actual: u32) -> i32 {
	if value < 0 {
		return -scale_metric(-value, requested, actual)
	}
	return i32((i64(value) * i64(requested) + i64(actual) / 2) / i64(actual))
}

scaled_color_metrics :: proc(face: ft.Face, requested, actual: u32) -> Metrics {
	return Metrics{
		advance_x = scale_metric(face.glyph.metrics.hori_advance, requested, actual),
		advance_y = scale_metric(face.glyph.metrics.vert_advance, requested, actual),
		bearing_x = scale_metric(ft.Pos(face.glyph.bitmap_left), requested, actual),
		bearing_y = scale_metric(ft.Pos(face.glyph.bitmap_top), requested, actual),
	}
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
