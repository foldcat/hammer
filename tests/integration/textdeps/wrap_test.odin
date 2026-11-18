package textdeps_test

import "core:testing"

import errs "hammer:core/errs"
import shaping "hammer:text/shaping"

wrap_fixture :: proc() -> shaping.Text {
	text: shaping.Text
	text.runs = make([dynamic]shaping.Run, 1)
	run := &text.runs[0]
	run.direction = .LTR
	run.clusters = make([dynamic]shaping.Cluster, 4)
	for index in 0 ..< 4 {
		run.clusters[index] = {
			source_start = index,
			source_end = index + 1,
			x = i32(index * 10 * 64),
			advance = 10 * 64,
		}
	}
	run.source_end = 4
	run.advance = 40 * 64
	text.total_advance = run.advance
	return text
}

@(test)
test_wrap_rows_split_only_at_cluster_boundaries :: proc(t: ^testing.T) {
	text := wrap_fixture()
	defer shaping.destroy(&text)
	rows, err := shaping.wrap_rows(text, 25, 1, context.allocator)
	if !expect_font_ok(t, err) {
		return
	}
	defer delete(rows)
	testing.expect(t, len(rows) == 2)
	testing.expect(t, rows[0] == shaping.Wrap_Row{start = 0, end = 20})
	testing.expect(t, rows[1] == shaping.Wrap_Row{start = 20, end = 40})

	first_hit, first_ok := shaping.hit_test_wrap_row(text, 18, rows[0])
	testing.expect(t, first_ok && first_hit.offset == 2)
	second_hit, second_ok := shaping.hit_test_wrap_row(text, 22, rows[1])
	testing.expect(t, second_ok && second_hit.offset == 2)
	end_hit, end_ok := shaping.hit_test_wrap_row(text, 22, rows[0])
	testing.expect(t, end_ok && end_hit.offset == 2)
}

@(test)
test_wrap_rows_empty_and_invalid_layout :: proc(t: ^testing.T) {
	text: shaping.Text
	rows, err := shaping.wrap_rows(text, 20, 1, context.allocator)
	if expect_font_ok(t, err) {
		testing.expect(t, len(rows) == 1 && rows[0] == shaping.Wrap_Row{})
		hit, ok := shaping.hit_test_wrap_row(text, 10, rows[0])
		testing.expect(t, ok && hit.offset == 0)
		delete(rows)
	}
	rows, err = shaping.wrap_rows(text, 0, 1, context.allocator)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	delete(rows)
}
