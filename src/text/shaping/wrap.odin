package shaping

import "core:math"

import errs "../../core/errs"

Wrap_Row :: struct {
	start: f32,
	end:   f32,
}

wrap_rows :: proc(text: Text, width, scale: f32, allocator := context.allocator) -> (rows: [dynamic]Wrap_Row, err: errs.Error) {
	rows = make([dynamic]Wrap_Row, allocator)
	defer if !errs.ok(err) {
		delete(rows)
	}
	if !valid_text_layout(text) || width <= 0 || !valid_dpi_scale(scale) || math.is_nan(width) || math.is_inf(width) {
		return rows, errs.new(.Invalid_Input, "shaping: invalid wrap layout or width", allocator = allocator)
	}
	if len(text.runs) == 0 {
		append(&rows, Wrap_Row{})
		return rows, {}
	}
	row_start := f32(0)
	row_end := f32(0)
	has_content := false
	for run in text.runs {
		for cluster in run.clusters {
			start := fixed_to_logical(f32(cluster.x), scale)
			end := fixed_to_logical(f32(cluster.x + cluster.advance), scale)
			if has_content && end - row_start > width && start > row_start {
				append(&rows, Wrap_Row{start = row_start, end = row_end})
				row_start = start
			}
			has_content = true
			row_end = end
		}
	}
	if has_content {
		append(&rows, Wrap_Row{start = row_start, end = row_end})
	}
	return rows, {}
}

hit_test_wrap_row :: proc(text: Text, x: f32, row: Wrap_Row, scale := f32(1)) -> (Caret, bool) {
	if !valid_text_layout(text) || !valid_dpi_scale(scale) || math.is_nan(x) || math.is_inf(x) ||
		row.start < 0 || row.end < row.start {
		return {}, false
	}
	if len(text.runs) == 0 {
		return Caret{x = 0}, true
	}
	fixed_x := x * 64 * scale
	found := false
	last_direction := Direction.LTR
	last_cluster := Cluster{}
	for run in text.runs {
		for cluster in run.clusters {
			cluster_x := fixed_to_logical(f32(cluster.x), scale)
			if cluster_x < row.start || cluster_x >= row.end {
				continue
			}
			found = true
			last_direction = run.direction
			last_cluster = cluster
			left := f32(cluster.x)
			right := f32(cluster.x + cluster.advance)
			if fixed_x < left {
				return caret_at_left(run.direction, cluster, fixed_to_logical(left, scale)), true
			}
			if fixed_x <= right {
				if fixed_x < (left + right) / 2 {
					return caret_at_left(run.direction, cluster, fixed_to_logical(left, scale)), true
				}
				return caret_at_right(run.direction, cluster, fixed_to_logical(right, scale)), true
			}
		}
	}
	if !found {
		return {}, false
	}
	return caret_at_right(last_direction, last_cluster, fixed_to_logical(f32(last_cluster.x + last_cluster.advance), scale)), true
}
