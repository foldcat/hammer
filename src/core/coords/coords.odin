// Package coords: logical/physical coordinate conversion (M01.03).
//
// The window backend reports everything in framebuffer (physical)
// pixels: `sapp.width()/height()` are pre-scaled and mouse events
// arrive in framebuffer pixels (docs/notes/m00-05-dpi-ime.md). The editor
// lays out in logical, DPI-independent units (SPECS.md §9.6), so
// physical values must be divided by the current `dpi_scale` — and
// logical values multiplied by it — exactly once. Never apply DPI
// twice.
//
// Font point sizes convert on the logical side only
// (`points_to_logical_px`, SPECS.md §9.6: logical px ≈ points × 96/72);
// the scale enters separately when logical px become physical px.
//
// `Physical_*` and `Logical_*` are distinct struct types so the two
// unit systems cannot be interchanged accidentally (AGENTS.md §9.3);
// conversions are the only crossing points.
//
// Backend-free: this package imports nothing but `core:` packages, so
// it builds without the Sokol collection (M01 acceptance).
package coords

import "core:math"

import errs "../errs"

// MAX_SCALE is the largest accepted physical/logical ratio. Real
// environments stay well below it (200%..500% desktop scaling, Xft.dpi
// up to ~480); the bound exists so a garbage scale (huge, zero,
// negative, non-finite) is reported instead of poisoning layout math.
MAX_SCALE :: 32.0

// POINTS_TO_LOGICAL_PX converts font points to logical pixels
// (SPECS.md §9.6): logical_px = points × 96/72.
POINTS_TO_LOGICAL_PX :: 96.0 / 72.0

// Physical_Size is a width/height in framebuffer pixels.
Physical_Size :: struct {
	width, height: f32,
}

// Physical_Point is an x/y position in framebuffer pixels.
Physical_Point :: struct {
	x, y: f32,
}

// Logical_Size is a width/height in DPI-independent layout units.
Logical_Size :: struct {
	width, height: f32,
}

// Logical_Point is an x/y position in DPI-independent layout units.
Logical_Point :: struct {
	x, y: f32,
}

// valid_scale reports whether `scale` is a usable physical/logical
// ratio: finite and within (0, MAX_SCALE].
valid_scale :: proc(scale: f32) -> bool {
	return scale > 0 && scale <= MAX_SCALE && !math.is_nan(scale) && !math.is_inf(scale)
}

// to_logical_size converts a physical framebuffer size to logical
// layout units (divide by `scale`). An invalid scale returns a zero
// size and an `.Invalid_Input` error; the caller decides the fallback
// (main falls back to scale 1.0) — a bad DPI value must never crash
// the editor (M01 acceptance).
to_logical_size :: proc(s: Physical_Size, scale: f32) -> (Logical_Size, errs.Error) {
	if !valid_scale(scale) {
		return {}, errs.newf(
			.Invalid_Input,
			"coords: invalid dpi scale %v (finite 0 < scale <= %v expected)",
			scale,
			MAX_SCALE,
		)
	}
	return Logical_Size{s.width / scale, s.height / scale}, {}
}

// to_logical_point converts a framebuffer-pixel position to logical
// layout units (divide by `scale`). See `to_logical_size` for the
// scale contract.
to_logical_point :: proc(p: Physical_Point, scale: f32) -> (Logical_Point, errs.Error) {
	if !valid_scale(scale) {
		return {}, errs.newf(
			.Invalid_Input,
			"coords: invalid dpi scale %v (finite 0 < scale <= %v expected)",
			scale,
			MAX_SCALE,
		)
	}
	return Logical_Point{p.x / scale, p.y / scale}, {}
}

// to_physical_size converts a logical layout size to framebuffer
// pixels (multiply by `scale`). See `to_logical_size` for the scale
// contract.
to_physical_size :: proc(s: Logical_Size, scale: f32) -> (Physical_Size, errs.Error) {
	if !valid_scale(scale) {
		return {}, errs.newf(
			.Invalid_Input,
			"coords: invalid dpi scale %v (finite 0 < scale <= %v expected)",
			scale,
			MAX_SCALE,
		)
	}
	return Physical_Size{s.width * scale, s.height * scale}, {}
}

// to_physical_point converts a logical layout position to framebuffer
// pixels (multiply by `scale`). See `to_logical_size` for the scale
// contract.
to_physical_point :: proc(p: Logical_Point, scale: f32) -> (Physical_Point, errs.Error) {
	if !valid_scale(scale) {
		return {}, errs.newf(
			.Invalid_Input,
			"coords: invalid dpi scale %v (finite 0 < scale <= %v expected)",
			scale,
			MAX_SCALE,
		)
	}
	return Physical_Point{p.x * scale, p.y * scale}, {}
}

// points_to_logical_px converts a font point size to logical pixels
// (SPECS.md §9.6: logical px ≈ points × 96/72). Pure arithmetic; the
// caller validates the point value's domain (the config schema bounds
// `font_size_points` at build time).
points_to_logical_px :: proc(points: f32) -> f32 {
	return points * POINTS_TO_LOGICAL_PX
}

// logical_px_to_points converts logical pixels back to font points;
// the inverse of `points_to_logical_px`.
logical_px_to_points :: proc(logical_px: f32) -> f32 {
	return logical_px / POINTS_TO_LOGICAL_PX
}

// points_to_physical_px converts a font point size to physical
// framebuffer pixels: points → logical px (×96/72), then logical px →
// physical px (× `scale`) — the full §9.6 chain in one call, so DPI is
// applied exactly once. An invalid scale returns `.Invalid_Input`.
points_to_physical_px :: proc(points: f32, scale: f32) -> (f32, errs.Error) {
	if !valid_scale(scale) {
		return 0, errs.newf(
			.Invalid_Input,
			"coords: invalid dpi scale %v (finite 0 < scale <= %v expected)",
			scale,
			MAX_SCALE,
		)
	}
	return points_to_logical_px(points) * scale, {}
}
