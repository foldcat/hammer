// Tests for the logical window geometry package (M01.06):
// `hammer:core/layout` — frame/tag/body rectangles, degenerate-size
// collapse, and input validation.
package layout_test

import "core:math"
import "core:testing"

import coords "hammer:core/coords"
import errs "hammer:core/errs"
import layout "hammer:core/layout"

expect_rect :: proc(t: ^testing.T, got: layout.Rect, want: layout.Rect, what: string) {
	testing.expectf(
		t,
		got == want,
		"%s: got {%v, %v, %v, %v}, want {%v, %v, %v, %v}",
		what,
		got.x,
		got.y,
		got.width,
		got.height,
		want.x,
		want.y,
		want.width,
		want.height,
	)
}

// test_basic_geometry pins the reference case: an 800x600 window with
// a 20-tall tag strip and 2px pad.
@(test)
test_basic_geometry :: proc(t: ^testing.T) {
	w, err := layout.window(coords.Logical_Size{800, 600}, 20, 2)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_rect(t, w.frame, {0, 0, 800, 600}, "frame")
	expect_rect(t, w.tag, {2, 2, 796, 20}, "tag")
	expect_rect(t, w.body, {2, 22, 796, 576}, "body")
}

// test_zero_pad: without padding the inner area is the whole window.
@(test)
test_zero_pad :: proc(t: ^testing.T) {
	w, err := layout.window(coords.Logical_Size{800, 600}, 20, 0)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_rect(t, w.tag, {0, 0, 800, 20}, "tag")
	expect_rect(t, w.body, {0, 20, 800, 580}, "body")
}

// test_zero_tag_height: the body takes the whole inner area.
@(test)
test_zero_tag_height :: proc(t: ^testing.T) {
	w, err := layout.window(coords.Logical_Size{800, 600}, 0, 2)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_rect(t, w.tag, {2, 2, 796, 0}, "tag")
	expect_rect(t, w.body, {2, 2, 796, 596}, "body")
}

// test_degenerate_sizes: M01 acceptance "resize does not crash" — a
// zero-sized window and an oversized pad/tag collapse to empty
// rectangles with valid geometry, never negative sizes.
@(test)
test_degenerate_sizes :: proc(t: ^testing.T) {
	// zero window
	w, err := layout.window(coords.Logical_Size{0, 0}, 20, 2)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_rect(t, w.frame, {0, 0, 0, 0}, "zero frame")
	expect_rect(t, w.tag, {0, 0, 0, 0}, "zero tag")
	expect_rect(t, w.body, {0, 0, 0, 0}, "zero body")

	// pad wider than the window
	w2, err2 := layout.window(coords.Logical_Size{10, 10}, 20, 8)
	defer errs.destroy(&err2)
	testing.expect(t, errs.ok(err2))
	testing.expect(t, w2.tag.width >= 0 && w2.body.width >= 0 && w2.body.height >= 0)
	expect_rect(t, w2.tag, {8, 8, 0, 0}, "oversized pad tag")

	// tag taller than the inner area: body collapses, tag takes it all
	w3, err3 := layout.window(coords.Logical_Size{100, 50}, 1000, 2)
	defer errs.destroy(&err3)
	testing.expect(t, errs.ok(err3))
	expect_rect(t, w3.tag, {2, 2, 96, 46}, "tall tag")
	expect_rect(t, w3.body, {2, 48, 96, 0}, "collapsed body")
}

// test_invalid_inputs: NaN/Inf/negative values are value errors
// (`.Invalid_Input`), never assertions.
@(test)
test_invalid_inputs :: proc(t: ^testing.T) {
	nan := math.inf_f32(1) - math.inf_f32(1)
	cases := []struct {
		size:       coords.Logical_Size,
		tag_height: f32,
		pad:        f32,
	} {
		{{-1, 600}, 20, 2},
		{{800, -1}, 20, 2},
		{{nan, 600}, 20, 2},
		{{800, math.inf_f32(1)}, 20, 2},
		{{800, 600}, -1, 2},
		{{800, 600}, nan, 2},
		{{800, 600}, math.inf_f32(1), 2},
		{{800, 600}, 20, -0.1},
		{{800, 600}, 20, nan},
		{{800, 600}, 20, math.inf_f32(1)},
	}
	for c in cases {
		_, err := layout.window(c.size, c.tag_height, c.pad)
		testing.expectf(t, !errs.ok(err), "case %v: expected an error", c)
		testing.expectf(t, err.kind == .Invalid_Input, "case %v: got kind %v", c, err.kind)
		errs.destroy(&err)
	}
}

// test_partition_invariant: tag + body always partition the inner
// area exactly (tag ends where the body begins, heights sum up).
@(test)
test_partition_invariant :: proc(t: ^testing.T) {
	sizes := []coords.Logical_Size{{800, 600}, {1024, 768}, {1, 1}, {320, 200}, {400.5, 300.25}}
	tag_heights := []f32{0, 1, 20, 57.5}
	pads := []f32{0, 2, 10}
	for size in sizes {
		for tag_height in tag_heights {
			for pad in pads {
				w, err := layout.window(size, tag_height, pad)
				defer errs.destroy(&err)
				testing.expect(t, errs.ok(err))
				testing.expect(t, w.tag.y + w.tag.height == w.body.y)
				testing.expect(t, w.tag.height + w.body.height == w.body.y + w.body.height - w.tag.y)
				testing.expect(t, w.tag.x == w.body.x && w.tag.width == w.body.width)
			}
		}
	}
}
