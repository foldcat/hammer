package dpi

import "core:math"

import coords "../coords"
import errs "../errs"

State :: struct {
	points:              f32,
	scale:               f32,
	physical_pixel_size: f32,
	glyph_pixel_size:    u32,
	generation:          u64,
}

Change :: struct {
	layout_changed: bool,
	glyph_changed:  bool,
	generation:     u64,
}

update :: proc(state: ^State, points, scale: f32, allocator := context.allocator) -> (Change, errs.Error) {
	if points <= 0 || math.is_nan(points) || math.is_inf(points) {
		return {}, errs.new(.Invalid_Input, "dpi: font points must be finite and positive", allocator = allocator)
	}
	physical, err := coords.points_to_physical_px(points, scale)
	if !errs.ok(err) {
		return {}, err
	}
	if physical > f32(max(u32) - 1) {
		return {}, errs.new(.Resource_Limit, "dpi: physical font size exceeds the supported integer range", allocator = allocator)
	}
	pixel_size := u32(physical + 0.5)
	if pixel_size == 0 {
		pixel_size = 1
	}
	change := Change{
		layout_changed = state.points != points || state.scale != scale,
		glyph_changed = state.glyph_pixel_size != pixel_size,
	}
	if change.layout_changed || change.glyph_changed {
		state.generation += 1
	}
	state.points = points
	state.scale = scale
	state.physical_pixel_size = physical
	state.glyph_pixel_size = pixel_size
	change.generation = state.generation
	return change, errs.Error{}
}

Rect :: struct {
	x, y:          i32,
	width, height: i32,
}

Monitor :: struct {
	bounds: Rect,
	dpi:    f32,
}

MAX_MONITORS :: 64

physical_dpi :: proc(pixels, millimeters: i32) -> (f32, bool) {
	if pixels <= 0 || millimeters <= 0 {
		return 0, false
	}
	value := f32(f64(pixels) * 25.4 / f64(millimeters))
	if value <= 0 || math.is_nan(value) || math.is_inf(value) {
		return 0, false
	}
	return value, true
}

monitor_scale :: proc(base_scale, reference_dpi, current_dpi: f32) -> (f32, bool) {
	if base_scale <= 0 || reference_dpi <= 0 || current_dpi <= 0 ||
	   math.is_nan(base_scale) || math.is_inf(base_scale) ||
	   math.is_nan(reference_dpi) || math.is_inf(reference_dpi) ||
	   math.is_nan(current_dpi) || math.is_inf(current_dpi) {
		return 0, false
	}
	scale := base_scale * current_dpi / reference_dpi
	if scale <= 0 || scale > coords.MAX_SCALE || math.is_nan(scale) || math.is_inf(scale) {
		return 0, false
	}
	return scale, true
}

select_monitor :: proc(window: Rect, monitors: []Monitor) -> int {
	if window.width <= 0 || window.height <= 0 {
		return -1
	}
	best := -1
	best_area := f64(0)
	best_distance := math.inf_f64(1)
	center_x := f64(window.x) + f64(window.width) / 2
	center_y := f64(window.y) + f64(window.height) / 2
	for monitor, index in monitors {
		bounds := monitor.bounds
		if bounds.width <= 0 || bounds.height <= 0 {
			continue
		}
		left := f64(max(window.x, bounds.x))
		top := f64(max(window.y, bounds.y))
		right := min(f64(window.x) + f64(window.width), f64(bounds.x) + f64(bounds.width))
		bottom := min(f64(window.y) + f64(window.height), f64(bounds.y) + f64(bounds.height))
		area := f64(0)
		if right > left && bottom > top {
			area = (right - left) * (bottom - top)
		}
		if area > 0 {
			if area > best_area {
				best = index
				best_area = area
				best_distance = 0
			}
			continue
		}
		if best_area > 0 {
			continue
		}
		closest_x := clamp(center_x, f64(bounds.x), f64(bounds.x) + f64(bounds.width))
		closest_y := clamp(center_y, f64(bounds.y), f64(bounds.y) + f64(bounds.height))
		dx := center_x - closest_x
		dy := center_y - closest_y
		distance := dx * dx + dy * dy
		if distance < best_distance {
			best = index
			best_distance = distance
		}
	}
	return best
}
