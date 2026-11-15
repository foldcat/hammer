package textdeps_test

import "core:testing"

import shaping "hammer:text/shaping"

@(test)
test_visible_ten_megabyte_line_is_bounded :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	bytes := make([]u8, 10 * 1024 * 1024)
	defer delete(bytes)
	for &b in bytes {
		b = 'a'
	}
	line := string(bytes)
	cursor: shaping.Measurement
	first, err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 4096)
	if !expect_font_ok(t, err) {
		return
	}
	defer shaping.destroy(&first.text)
	testing.expect(t, first.start == 0 && first.end > 0 && first.end <= 4096)
	testing.expect(t, !first.done && first.segmented)
	testing.expect(t, cursor.offset == first.end && cursor.advance == i64(first.text.total_advance))
	for run in first.text.runs {
		testing.expect(t, run.source_start >= first.start && run.source_end <= first.end)
	}

	second, second_err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 4096)
	if !expect_font_ok(t, second_err) {
		return
	}
	defer shaping.destroy(&second.text)
	testing.expect(t, second.start == first.end && second.end > second.start && second.end - second.start <= 4096)
	testing.expect(t, cursor.advance == i64(first.text.total_advance) + i64(second.text.total_advance))
}

@(test)
test_visible_incremental_measurement_completes :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	bytes := make([]u8, 2 * 1024 * 1024 + 17)
	defer delete(bytes)
	for &b in bytes {
		b = 'x'
	}
	line := string(bytes)
	cursor: shaping.Measurement
	calls := 0
	sum := i64(0)
	for cursor.offset < len(line) {
		calls += 1
		if !testing.expect(t, calls <= 40) {
			return
		}
		visible, err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16})
		if !expect_font_ok(t, err) {
			return
		}
		testing.expect(t, visible.end > visible.start && visible.end - visible.start <= shaping.DEFAULT_VISIBLE_BYTES)
		testing.expect(t, visible.segmented)
		sum += i64(visible.text.total_advance)
		testing.expect(t, cursor.advance == sum)
		shaping.destroy(&visible.text)
	}
	testing.expect(t, cursor.offset == len(line) && cursor.advance == sum)
}

@(test)
test_visible_preserves_graphemes_and_absolute_offsets :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [1]shaping.Font{{font_id = 1, native = rawptr(fixtures.mono)}}
	line := "abA\u0301cd👩\u200d💻Bxyz"
	reference := shape_fixture(t, line, fonts[:])
	defer shaping.destroy(&reference)
	expected: [16]shaping.Byte_Range
	expected_count := 0
	for run in reference.runs {
		for cluster in run.clusters {
			expected[expected_count] = {start = cluster.source_start, end = cluster.source_end}
			expected_count += 1
		}
	}

	cursor: shaping.Measurement
	actual_count := 0
	advance := i64(0)
	for cursor.offset < len(line) {
		visible, err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 12)
		if !expect_font_ok(t, err) {
			return
		}
		testing.expect(t, visible.segmented)
		for run in visible.text.runs {
			testing.expect(t, run.source_start >= visible.start && run.source_end <= visible.end)
			for cluster in run.clusters {
				if testing.expect(t, actual_count < expected_count) {
					testing.expect(t, cluster.source_start == expected[actual_count].start)
					testing.expect(t, cluster.source_end == expected[actual_count].end)
				}
				actual_count += 1
			}
		}
		advance += i64(visible.text.total_advance)
		shaping.destroy(&visible.text)
	}
	testing.expect(t, actual_count == expected_count)
	testing.expect(t, advance == i64(reference.total_advance))
}

@(test)
test_visible_segmented_bidi_fallback_and_errors :: proc(t: ^testing.T) {
	fixtures := fixture_fonts_open(t)
	defer fixture_fonts_destroy(&fixtures)
	fonts := [2]shaping.Font{
		{font_id = 1, native = rawptr(fixtures.mono)},
		{font_id = 2, native = rawptr(fixtures.hebrew)},
	}
	cursor: shaping.Measurement
	line := "abc אבג def אבג"
	first, first_err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 6)
	if !expect_font_ok(t, first_err) {
		return
	}
	shaping.destroy(&first.text)
	second, second_err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 6)
	if !expect_font_ok(t, second_err) {
		return
	}
	defer shaping.destroy(&second.text)
	testing.expect(t, second.start > 0 && second.segmented)
	checked_caret := false
	for run in second.text.runs {
		testing.expect(t, run.source_start >= second.start && run.source_end <= second.end)
		for cluster in run.clusters {
			testing.expect(t, cluster.source_start >= second.start && cluster.source_end <= second.end)
			if !checked_caret {
				x, ok := shaping.caret_position(second.text, cluster.source_start, .Leading)
				hit, hit_ok := shaping.hit_test(second.text, x)
				testing.expect(t, ok && hit_ok && hit.offset == cluster.source_start)
				checked_caret = true
			}
		}
	}

	bad_cursor := shaping.Measurement{offset = len(line) + 1}
	_, cursor_err := shaping.visible_next(line, &bad_cursor, fonts[:], {pixel_size = 16})
	testing.expect(t, cursor_err.kind == .Invalid_Input)
	errs_destroy_shape(&cursor_err)
	_, budget_err := shaping.visible_next(line, &cursor, fonts[:], {pixel_size = 16}, 0)
	testing.expect(t, budget_err.kind == .Invalid_Input)
	errs_destroy_shape(&budget_err)

	grapheme_cursor: shaping.Measurement
	before := grapheme_cursor
	_, grapheme_err := shaping.visible_next("A\u0301", &grapheme_cursor, fonts[:], {pixel_size = 16}, 1)
	testing.expect(t, grapheme_err.kind == .Resource_Limit)
	testing.expect(t, grapheme_cursor == before)
	errs_destroy_shape(&grapheme_err)

	invalid_bytes := [1]u8{0xff}
	invalid_cursor: shaping.Measurement
	_, invalid_err := shaping.visible_next(string(invalid_bytes[:]), &invalid_cursor, fonts[:], {pixel_size = 16}, 16)
	testing.expect(t, invalid_err.kind == .Invalid_Input)
	testing.expect(t, invalid_cursor.offset == 0)
	errs_destroy_shape(&invalid_err)

	short_cursor: shaping.Measurement
	short, short_err := shaping.visible_next("abc", &short_cursor, fonts[:], {pixel_size = 16})
	if expect_font_ok(t, short_err) {
		defer shaping.destroy(&short.text)
		testing.expect(t, short.done && !short.segmented && short.start == 0 && short.end == 3)
	}
	empty_cursor: shaping.Measurement
	empty, empty_err := shaping.visible_next("", &empty_cursor, fonts[:], {pixel_size = 16})
	if expect_font_ok(t, empty_err) {
		defer shaping.destroy(&empty.text)
		testing.expect(t, empty.done && !empty.segmented && empty.start == 0 && empty.end == 0)
	}
}
