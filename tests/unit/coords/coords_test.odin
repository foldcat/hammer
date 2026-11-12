// Tests for the logical/physical coordinate conversion package
// (M01.03): `hammer:core/coords` — the SPECS.md §9.6 DPI model
// (logical layout units, divide/multiply by dpi_scale exactly once,
// points → logical px × 96/72) and the scale-validation contract
// (bad scales degrade, never crash).
package coords_test

import "core:math"
import "core:testing"

import coords "hammer:core/coords"
import errs "hammer:core/errs"

expect_near :: proc(t: ^testing.T, got, want: f32, what: string, epsilon := f32(0.0001)) {
	testing.expectf(
		t,
		math.abs(got - want) <= epsilon,
		"%s: got %v, want %v (+/- %v)",
		what,
		got,
		want,
		epsilon,
	)
}

// test_identity verifies the scale-1.0 identity: conversion in either
// direction is a no-op at 100%.
@(test)
test_identity :: proc(t: ^testing.T) {
	phys := coords.Physical_Size{1920, 1080}
	logical, err := coords.to_logical_size(phys, 1.0)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_near(t, logical.width, 1920, "logical.width")
	expect_near(t, logical.height, 1080, "logical.height")

	back, err2 := coords.to_physical_size(logical, 1.0)
	defer errs.destroy(&err2)
	testing.expect(t, errs.ok(err2))
	expect_near(t, back.width, 1920, "physical.width")
	expect_near(t, back.height, 1080, "physical.height")
}

// test_physical_to_logical_table exercises the SPECS.md §9.6 scale
// test values (100%, 125%, 150%, 200%) on framebuffer sizes.
@(test)
test_physical_to_logical_table :: proc(t: ^testing.T) {
	Cases :: struct {
		scale:      f32,
		phys:       coords.Physical_Size,
		want:       coords.Logical_Size,
	}
	cases := []Cases {
		{1.0, {800, 600}, {800, 600}},
		{1.25, {100, 100}, {80, 80}},
		{1.5, {1920, 1080}, {1280, 720}},
		{2.0, {800, 600}, {400, 300}},
		{2.0, {3840, 2160}, {1920, 1080}},
	}
	for c in cases {
		got, err := coords.to_logical_size(c.phys, c.scale)
		defer errs.destroy(&err)
		testing.expectf(t, errs.ok(err), "scale %v: unexpected error %v", c.scale, errs.describe(err))
		expect_near(t, got.width, c.want.width, "logical.width")
		expect_near(t, got.height, c.want.height, "logical.height")
	}
}

// test_roundtrip converts logical → physical → logical at fractional
// scales; the two conversions must be exact inverses (apply the scale
// twice, once in each direction, without drift).
@(test)
test_roundtrip :: proc(t: ^testing.T) {
	scales := []f32{0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0}
	start := coords.Logical_Size{533.25, 411.5}
	for scale in scales {
		phys, err := coords.to_physical_size(start, scale)
		defer errs.destroy(&err)
		testing.expect(t, errs.ok(err))
		back, err2 := coords.to_logical_size(phys, scale)
		defer errs.destroy(&err2)
		testing.expect(t, errs.ok(err2))
		expect_near(t, back.width, start.width, "roundtrip.width")
		expect_near(t, back.height, start.height, "roundtrip.height")
	}
}

// test_fractional_hit_testing covers fractional-scale positions
// (SPECS.md §9.6: "Hit-testing at fractional scale"): logical values
// map to fractional framebuffer positions and back.
@(test)
test_fractional_hit_testing :: proc(t: ^testing.T) {
	phys, err := coords.to_physical_point(coords.Logical_Point{3.3, 7.7}, 1.5)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_near(t, phys.x, 4.95, "physical.x")
	expect_near(t, phys.y, 11.55, "physical.y")

	// Mouse events arrive in framebuffer pixels (integer-ish values
	// from the backend); hit-testing recovers the logical position.
	logical, err2 := coords.to_logical_point(coords.Physical_Point{5, 12}, 1.5)
	defer errs.destroy(&err2)
	testing.expect(t, errs.ok(err2))
	expect_near(t, logical.x, 3.3333333, "logical.x")
	expect_near(t, logical.y, 8.0, "logical.y")
}

// test_proportions_preserved checks SPECS.md §9.6.4: conversion scales
// width and height equally, so logical layout proportions survive.
@(test)
test_proportions_preserved :: proc(t: ^testing.T) {
	phys := coords.Physical_Size{960, 480}
	logical, err := coords.to_logical_size(phys, 2.0)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_near(t, logical.width/logical.height, 2.0, "logical aspect ratio")
	expect_near(t, phys.width/phys.height, 2.0, "physical aspect ratio")
}

// test_points_conversion covers the points ↔ logical px rule
// (logical px = points × 96/72) and the full points → physical chain.
@(test)
test_points_conversion :: proc(t: ^testing.T) {
	expect_near(t, coords.points_to_logical_px(12), 16, "12pt in logical px")
	expect_near(t, coords.points_to_logical_px(72), 96, "72pt in logical px")
	expect_near(t, coords.points_to_logical_px(9), 12, "9pt in logical px")
	expect_near(t, coords.logical_px_to_points(16), 12, "16 logical px in points")

	// 12pt at scale 2.0: 16 logical px, 32 physical px — the full
	// SPECS.md §9.6 chain applies the scale exactly once.
	phys, err := coords.points_to_physical_px(12, 2.0)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_near(t, phys, 32, "12pt at 2x in physical px")
}

// test_invalid_scales verifies the scale-validation contract: zero,
// negative, non-finite, and out-of-bounds scales are rejected with an
// `.Invalid_Input` error and a zero result — never a crash (M01
// acceptance: "resize and scale changes do not crash").
@(test)
test_invalid_scales :: proc(t: ^testing.T) {
	nan := math.inf_f32(1) - math.inf_f32(1)
	bad_scales := []f32 {
		0,
		-1,
		-0.5,
		nan,
		math.inf_f32(1),
		math.inf_f32(-1),
		coords.MAX_SCALE + 1,
	}
	for scale in bad_scales {
		s, err := coords.to_logical_size(coords.Physical_Size{800, 600}, scale)
		testing.expectf(t, !errs.ok(err), "scale %v: expected an error", scale)
		testing.expectf(
			t,
			err.kind == .Invalid_Input,
			"scale %v: expected .Invalid_Input, got %v",
			scale,
			err.kind,
		)
		testing.expect(t, s == coords.Logical_Size{}, "expected a zero result")
		errs.destroy(&err)

		p, perr := coords.to_logical_point(coords.Physical_Point{10, 20}, scale)
		testing.expect(t, !errs.ok(perr))
		testing.expect(t, p == coords.Logical_Point{})
		errs.destroy(&perr)

		ps, pserr := coords.to_physical_size(coords.Logical_Size{800, 600}, scale)
		testing.expect(t, !errs.ok(pserr))
		testing.expect(t, ps == coords.Physical_Size{})
		errs.destroy(&pserr)

		pp, pperr := coords.to_physical_point(coords.Logical_Point{10, 20}, scale)
		testing.expect(t, !errs.ok(pperr))
		testing.expect(t, pp == coords.Physical_Point{})
		errs.destroy(&pperr)

		fpx, ferr := coords.points_to_physical_px(12, scale)
		testing.expect(t, !errs.ok(ferr))
		testing.expect(t, fpx == 0)
		errs.destroy(&ferr)
	}
}

// test_scale_boundaries pins the accepted range: the smallest real
// scale (Xft.dpi=48 → 0.5) and MAX_SCALE itself are valid; anything
// beyond is not.
@(test)
test_scale_boundaries :: proc(t: ^testing.T) {
	s, err := coords.to_logical_size(coords.Physical_Size{800, 600}, 0.5)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	expect_near(t, s.width, 1600, "logical.width at 0.5")

	s2, err2 := coords.to_logical_size(coords.Physical_Size{800, 600}, coords.MAX_SCALE)
	defer errs.destroy(&err2)
	testing.expect(t, errs.ok(err2))
	expect_near(t, s2.width, 800/coords.MAX_SCALE, "logical.width at MAX_SCALE")

	_, err3 := coords.to_logical_size(coords.Physical_Size{800, 600}, coords.MAX_SCALE+0.001)
	defer errs.destroy(&err3)
	testing.expect(t, !errs.ok(err3))
}
