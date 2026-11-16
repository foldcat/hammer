package dpi_test

import "core:math"
import "core:testing"

import coords "hammer:core/coords"
import dpi "hammer:core/dpi"
import errs "hammer:core/errs"

expect_near :: proc(t: ^testing.T, got, want: f32) {
	testing.expectf(t, math.abs(got-want) < 0.0001, "got %v, want %v", got, want)
}

@(test)
test_scale_table_and_repeated_update :: proc(t: ^testing.T) {
	state: dpi.State
	cases := []struct {
		scale:      f32,
		physical:   f32,
		glyph_size: u32,
	} {
		{1.0, 16, 16},
		{1.25, 20, 20},
		{1.5, 24, 24},
		{2.0, 32, 32},
	}
	for item, index in cases {
		change, err := dpi.update(&state, 12, item.scale)
		defer errs.destroy(&err)
		testing.expect(t, errs.ok(err))
		testing.expect(t, change.layout_changed && change.glyph_changed)
		testing.expect(t, change.generation == u64(index + 1))
		expect_near(t, state.physical_pixel_size, item.physical)
		testing.expect(t, state.glyph_pixel_size == item.glyph_size)
		logical, logical_err := coords.to_logical_size(coords.Physical_Size{item.physical, item.physical}, item.scale)
		defer errs.destroy(&logical_err)
		testing.expect(t, errs.ok(logical_err))
		expect_near(t, logical.width, 16)
		expect_near(t, logical.height, 16)
	}
	change, err := dpi.update(&state, 12, 2)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	testing.expect(t, !change.layout_changed && !change.glyph_changed)
	testing.expect(t, change.generation == 4)
}

@(test)
test_fractional_scale_invalidates_layout_without_glyph_resize :: proc(t: ^testing.T) {
	state: dpi.State
	_, init_err := dpi.update(&state, 12, 1)
	defer errs.destroy(&init_err)
	testing.expect(t, errs.ok(init_err))

	change, err := dpi.update(&state, 12, 1.01)
	defer errs.destroy(&err)
	testing.expect(t, errs.ok(err))
	testing.expect(t, change.layout_changed)
	testing.expect(t, !change.glyph_changed)
	testing.expect(t, state.glyph_pixel_size == 16)
	expect_near(t, state.physical_pixel_size, 16.16)
}

@(test)
test_invalid_updates_preserve_last_valid_state :: proc(t: ^testing.T) {
	state: dpi.State
	_, init_err := dpi.update(&state, 12, 1.5)
	defer errs.destroy(&init_err)
	testing.expect(t, errs.ok(init_err))
	original := state

	bad_scales := []f32{0, -1, math.inf_f32(1), math.inf_f32(1) - math.inf_f32(1), coords.MAX_SCALE + 1}
	for scale in bad_scales {
		_, err := dpi.update(&state, 12, scale)
		testing.expect(t, !errs.ok(err))
		testing.expect(t, state == original)
		errs.destroy(&err)
	}
	bad_points := []f32{0, -12, math.inf_f32(1), math.inf_f32(1) - math.inf_f32(1)}
	for points in bad_points {
		_, err := dpi.update(&state, points, 1.5)
		testing.expect(t, !errs.ok(err))
		testing.expect(t, state == original)
		errs.destroy(&err)
	}
}

@(test)
test_monitor_selection_uses_largest_overlap :: proc(t: ^testing.T) {
	monitors := []dpi.Monitor {
		{bounds = {x = 0, y = 0, width = 1920, height = 1080}, dpi = 96},
		{bounds = {x = 1920, y = 0, width = 3840, height = 2160}, dpi = 192},
	}
	testing.expect(t, dpi.select_monitor({x = 100, y = 100, width = 800, height = 600}, monitors) == 0)
	testing.expect(t, dpi.select_monitor({x = 1600, y = 100, width = 800, height = 600}, monitors) == 1)
	testing.expect(t, dpi.select_monitor({x = -700, y = 100, width = 800, height = 600}, monitors) == 0)
	testing.expect(t, dpi.select_monitor({x = -1000, y = -1000, width = 100, height = 100}, monitors) == 0)
	testing.expect(t, dpi.select_monitor({x = 0, y = 0, width = 0, height = 100}, monitors) == -1)
	testing.expect(t, dpi.select_monitor({x = 0, y = 0, width = 100, height = 100}, nil) == -1)
}

@(test)
test_mixed_dpi_round_trip_and_invalid_monitor_data :: proc(t: ^testing.T) {
	high, ok := dpi.monitor_scale(1, 96, 192)
	testing.expect(t, ok)
	expect_near(t, high, 2)
	fractional, fractional_ok := dpi.monitor_scale(1, 96, 120)
	testing.expect(t, fractional_ok)
	expect_near(t, fractional, 1.25)
	base, base_ok := dpi.monitor_scale(1, 96, 96)
	testing.expect(t, base_ok)
	expect_near(t, base, 1)

	invalid_values := [][3]f32{{0, 96, 96}, {1, 0, 96}, {1, 96, 0}, {1, 96, math.inf_f32(1)}, {32, 96, 192}}
	for values in invalid_values {
		_, valid := dpi.monitor_scale(values[0], values[1], values[2])
		testing.expect(t, !valid)
	}
	value, value_ok := dpi.physical_dpi(1920, 508)
	testing.expect(t, value_ok)
	expect_near(t, value, 96)
	_, invalid := dpi.physical_dpi(1920, 0)
	testing.expect(t, !invalid)
}


@(test)
test_zoom_steps_reset_bounds_and_invalid_input :: proc(t: ^testing.T) {
	next, changed := dpi.next_zoom_points(12, 12, .In)
	testing.expect(t, changed)
	expect_near(t, next, 13)
	next, changed = dpi.next_zoom_points(next, 12, .Out)
	testing.expect(t, changed)
	expect_near(t, next, 12)
	next, changed = dpi.next_zoom_points(18, 12, .Reset)
	testing.expect(t, changed)
	expect_near(t, next, 12)
	_, changed = dpi.next_zoom_points(12, 12, .Reset)
	testing.expect(t, !changed)

	next, changed = dpi.next_zoom_points(dpi.MAX_ZOOM_POINTS, 12, .In)
	testing.expect(t, !changed)
	expect_near(t, next, dpi.MAX_ZOOM_POINTS)
	next, changed = dpi.next_zoom_points(dpi.MIN_ZOOM_POINTS, 12, .Out)
	testing.expect(t, !changed)
	expect_near(t, next, dpi.MIN_ZOOM_POINTS)
	next, changed = dpi.next_zoom_points(71.5, 12, .In)
	testing.expect(t, changed)
	expect_near(t, next, dpi.MAX_ZOOM_POINTS)
	next, changed = dpi.next_zoom_points(4.5, 12, .Out)
	testing.expect(t, changed)
	expect_near(t, next, dpi.MIN_ZOOM_POINTS)

	invalid := []f32{0, 3.9, 72.1, math.inf_f32(1), math.inf_f32(1) - math.inf_f32(1)}
	for value in invalid {
		next, changed = dpi.next_zoom_points(value, 12, .In)
		testing.expect(t, !changed)
		testing.expect(t, next == value || math.is_nan(next) && math.is_nan(value))
		next, changed = dpi.next_zoom_points(12, value, .Reset)
		testing.expect(t, !changed && next == 12)
	}
	next, changed = dpi.next_zoom_points(12, 12, dpi.Zoom_Action(99))
	testing.expect(t, !changed && next == 12)
}
