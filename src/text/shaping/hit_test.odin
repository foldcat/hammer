package shaping

import "core:math"

import coords "../../core/coords"
import errs "../../core/errs"

Edge :: enum u8 {
	Leading,
	Trailing,
}

Caret :: struct {
	offset: int,
	edge:   Edge,
	x:      f32,
}

Selection_Span :: struct {
	start: f32,
	end:   f32,
}

// hit_test maps a logical x coordinate to a grapheme-safe source byte offset.
// Scale is the physical/logical ratio used to shape the runs. Leading/trailing
// edges preserve which logical side was chosen in bidi text.
hit_test :: proc(text: Text, x: f32, scale := f32(1)) -> (Caret, bool) {
	if !valid_dpi_scale(scale) || !valid_text_layout(text) || math.is_nan(x) || math.is_inf(x) {
		return {}, false
	}
	if len(text.runs) == 0 {
		return Caret{x = 0}, true
	}

	fixed_x := x * 64 * scale
	for run in text.runs {
		for cluster in run.clusters {
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
	last_run := text.runs[len(text.runs) - 1]
	last := last_run.clusters[len(last_run.clusters) - 1]
	return caret_at_right(last_run.direction, last, fixed_to_logical(f32(last.x + last.advance), scale)), true
}

// caret_position returns the logical x coordinate for a source byte offset.
// Interior codepoint bytes are rejected. At text start/end, either edge uses
// the only available caret position.
caret_position :: proc(text: Text, offset: int, edge: Edge, scale := f32(1)) -> (f32, bool) {
	if !valid_dpi_scale(scale) || edge != .Leading && edge != .Trailing || !valid_text_layout(text) {
		return 0, false
	}
	if len(text.runs) == 0 {
		return 0, offset == 0
	}
	for run in text.runs {
		for cluster in run.clusters {
			if edge == .Leading && offset == cluster.source_start {
				return leading_x(run.direction, cluster, scale), true
			}
			if edge == .Trailing && offset == cluster.source_end {
				return trailing_x(run.direction, cluster, scale), true
			}
		}
	}

	first, last := logical_extents(text)
	if offset == first {
		for run in text.runs {
			for cluster in run.clusters {
				if cluster.source_start == first {
					return leading_x(run.direction, cluster, scale), true
				}
			}
		}
	}
	if offset == last {
		for run in text.runs {
			for cluster in run.clusters {
				if cluster.source_end == last {
					return trailing_x(run.direction, cluster, scale), true
				}
			}
		}
	}
	return 0, false
}

// selection_spans returns owned visual-order logical x spans for a logical
// source range. Disjoint bidi selections remain disjoint; adjacent selected
// graphemes are coalesced. Destroy the result with delete.
selection_spans :: proc(text: Text, start, end: int, scale := f32(1), allocator := context.allocator) -> ([dynamic]Selection_Span, errs.Error) {
	spans := make([dynamic]Selection_Span, allocator)
	if !valid_dpi_scale(scale) {
		delete(spans)
		return nil, errs.new(.Invalid_Input, "shaping: invalid DPI scale", allocator = allocator)
	}
	if !valid_text_layout(text) {
		delete(spans)
		return nil, errs.new(.Invalid_Input, "shaping: invalid cluster layout", allocator = allocator)
	}
	if !valid_caret_offset(text, start) || !valid_caret_offset(text, end) {
		delete(spans)
		return nil, errs.new(.Invalid_Input, "shaping: selection endpoint is not a grapheme boundary", allocator = allocator)
	}
	selection_start := min(start, end)
	selection_end := max(start, end)
	if selection_start == selection_end {
		return spans, {}
	}

	for run in text.runs {
		for cluster in run.clusters {
			if cluster.source_start >= selection_end || cluster.source_end <= selection_start {
				continue
			}
			left := fixed_to_logical(f32(cluster.x), scale)
			right := fixed_to_logical(f32(cluster.x + cluster.advance), scale)
			if len(spans) > 0 && spans[len(spans) - 1].end == left {
				spans[len(spans) - 1].end = right
			} else {
				append(&spans, Selection_Span{start = left, end = right})
			}
		}
	}
	return spans, {}
}

caret_at_left :: proc(direction: Direction, cluster: Cluster, x: f32) -> Caret {
	if direction == .RTL {
		return Caret{offset = cluster.source_end, edge = .Trailing, x = x}
	}
	return Caret{offset = cluster.source_start, edge = .Leading, x = x}
}

caret_at_right :: proc(direction: Direction, cluster: Cluster, x: f32) -> Caret {
	if direction == .RTL {
		return Caret{offset = cluster.source_start, edge = .Leading, x = x}
	}
	return Caret{offset = cluster.source_end, edge = .Trailing, x = x}
}

leading_x :: proc(direction: Direction, cluster: Cluster, scale: f32) -> f32 {
	if direction == .RTL {
		return fixed_to_logical(f32(cluster.x + cluster.advance), scale)
	}
	return fixed_to_logical(f32(cluster.x), scale)
}

trailing_x :: proc(direction: Direction, cluster: Cluster, scale: f32) -> f32 {
	if direction == .RTL {
		return fixed_to_logical(f32(cluster.x), scale)
	}
	return fixed_to_logical(f32(cluster.x + cluster.advance), scale)
}

fixed_to_logical :: proc(x: f32, scale: f32) -> f32 {
	return x / (64 * scale)
}

logical_extents :: proc(text: Text) -> (int, int) {
	first := text.runs[0].source_start
	last := text.runs[0].source_end
	for run in text.runs[1:] {
		first = min(first, run.source_start)
		last = max(last, run.source_end)
	}
	return first, last
}

valid_caret_offset :: proc(text: Text, offset: int) -> bool {
	if len(text.runs) == 0 {
		return offset == 0
	}
	for run in text.runs {
		for cluster in run.clusters {
			if offset == cluster.source_start || offset == cluster.source_end {
				return true
			}
		}
	}
	return false
}

valid_dpi_scale :: proc(scale: f32) -> bool {
	return scale > 0 && scale <= coords.MAX_SCALE && !math.is_nan(scale) && !math.is_inf(scale)
}

valid_text_layout :: proc(text: Text) -> bool {
	if len(text.runs) == 0 {
		return text.total_advance == 0
	}
	expected_x := i32(0)
	for run in text.runs {
		if len(run.clusters) == 0 || (run.direction != .LTR && run.direction != .RTL) {
			return false
		}
		run_start := expected_x
		expected_source := run.source_start
		if run.direction == .RTL {
			expected_source = run.source_end
		}
		for cluster in run.clusters {
			if cluster.x != expected_x || cluster.advance < 0 ||
				cluster.source_start < run.source_start || cluster.source_end > run.source_end ||
				cluster.source_start >= cluster.source_end {
				return false
			}
			if run.direction == .RTL {
				if cluster.source_end != expected_source {
					return false
				}
				expected_source = cluster.source_start
			} else {
				if cluster.source_start != expected_source {
					return false
				}
				expected_source = cluster.source_end
			}
			expected_x += cluster.advance
		}
		if run.direction == .RTL && expected_source != run.source_start ||
			run.direction == .LTR && expected_source != run.source_end ||
			run.advance != expected_x - run_start {
			return false
		}
	}
	return expected_x == text.total_advance
}
