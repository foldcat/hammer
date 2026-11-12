// Package layout: logical window geometry (M01.06).
//
// The first visible slice of the editor shell: a window's outer frame
// and the tag strip and body area inside it, computed in logical
// units (SPECS.md §9.6) so the same numbers work at every DPI scale.
// The application layer converts to framebuffer pixels with
// `core/coords` when rendering.
//
// M07 builds the real column/window layout (multiple windows per
// column, dragging, scrollbars) on these types; this package stays
// the backend-free geometry core.
package layout

import "core:math"

import coords "../coords"
import errs "../errs"

// Rect is an axis-aligned rectangle in logical units. Width/height
// are always non-negative.
Rect :: struct {
	x, y:          f32,
	width, height: f32,
}

// Window is the basic window geometry (M01.06): the outer frame (the
// whole window, including the border padding around the inner area),
// the tag strip at the top of the inner area, and the body below it.
Window :: struct {
	frame: Rect,
	tag:   Rect,
	body:  Rect,
}

// window computes the window geometry for a window of logical size
// `size`: the frame covers the whole window; the inner area is the
// frame inset by `pad` on every side; the tag strip is `tag_height`
// tall at the top of the inner area; the body fills the remainder.
//
// Contract: inputs must be finite and non-negative. Degenerate sizes
// (zero area, pad wider than the window, tag taller than the inner
// area) collapse to empty rectangles instead of failing — a window
// resized to zero must not crash the editor (M01 acceptance).
// Non-finite or negative inputs return `.Invalid_Input`.
window :: proc(size: coords.Logical_Size, tag_height, pad: f32) -> (Window, errs.Error) {
	if !finite_nonneg(size.width) || !finite_nonneg(size.height) || !finite_nonneg(tag_height) || !finite_nonneg(pad) {
		return {}, errs.newf(
			.Invalid_Input,
			"layout: invalid size %vx%v, tag_height %v, pad %v (finite non-negative values expected)",
			size.width,
			size.height,
			tag_height,
			pad,
		)
	}

	// The pad clamps on each side independently so a pad wider than
	// half the window collapses the inner area to zero instead of
	// producing negative rectangles.
	left := min(pad, size.width)
	right := min(pad, size.width - left)
	top := min(pad, size.height)
	bottom := min(pad, size.height - top)

	inner := Rect {
		x = left,
		y = top,
		width = size.width - left - right,
		height = size.height - top - bottom,
	}
	tag_h := min(tag_height, inner.height)
	return Window {
		frame = {0, 0, size.width, size.height},
		tag = {inner.x, inner.y, inner.width, tag_h},
		body = {inner.x, inner.y + tag_h, inner.width, inner.height - tag_h},
	}, {}
}

// finite_nonneg reports whether `v` is a finite, non-negative value.
finite_nonneg :: proc(v: f32) -> bool {
	return !math.is_nan(v) && !math.is_inf(v) && v >= 0
}
