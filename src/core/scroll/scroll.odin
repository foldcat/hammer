package scroll

import "core:math"

import coords "../coords"
import input "../input"
import layout "../layout"

WIDTH :: f32(12)
MIN_THUMB_HEIGHT :: f32(8)
MIN_REPEAT_MS :: u64(40)
MAX_REPEAT_MS :: u64(260)

Action_Kind :: enum u8 {
	Relative,
	Absolute,
}

Action :: struct {
	window_id: layout.Window_ID,
	kind:      Action_Kind,
	delta:     int,
	fraction:  f32,
}

State :: struct {
	window_id:      layout.Window_ID,
	buttons:        input.Mouse_Buttons,
	track:          layout.Rect,
	position:       f32,
	next_repeat_ms: u64,
}

body_rects :: proc(body: layout.Rect) -> (track, text: layout.Rect) {
	track = body
	track.width = min(WIDTH, max(0, body.width))
	text = body
	text.x += track.width
	text.width = max(0, body.width - track.width)
	return track, text
}

thumb_rect :: proc(track: layout.Rect, first_line, first_row, first_line_rows, line_count, visible_rows: int) -> layout.Rect {
	thumb := track
	if track.width <= 0 || track.height <= 0 || line_count <= 0 || visible_rows <= 0 {
		return {}
	}
	visible_fraction := min(1, f32(visible_rows) / f32(line_count))
	thumb.height = min(track.height, max(min(MIN_THUMB_HEIGHT, track.height), track.height * visible_fraction))
	if line_count <= visible_rows || line_count == 1 {
		thumb.height = track.height
		return thumb
	}
	rows := max(1, first_line_rows)
	local := clamp(f32(max(0, first_row)) / f32(rows), 0, 1)
	origin := clamp((f32(clamp(first_line, 0, line_count - 1)) + local) / f32(max(1, line_count - 1)), 0, 1)
	thumb.y += origin * (track.height - thumb.height)
	return thumb
}

absolute_line :: proc(fraction: f32, line_count: int) -> int {
	if line_count <= 1 || math.is_nan(fraction) || math.is_inf(fraction) {
		return 0
	}
	return clamp(int(clamp(fraction, 0, 1) * f32(line_count - 1) + 0.5), 0, line_count - 1)
}

reveal_caret_right :: proc(offset, caret_x, viewport_width, max_offset: f32) -> f32 {
	if math.is_nan(offset) || math.is_inf(offset) || math.is_nan(caret_x) || math.is_inf(caret_x) ||
		math.is_nan(viewport_width) || math.is_inf(viewport_width) || math.is_nan(max_offset) || math.is_inf(max_offset) {
		return 0
	}
	limit := max(0, max_offset)
	bounded := clamp(offset, 0, limit)
	if viewport_width <= 0 {
		return bounded
	}
	return clamp(max(bounded, caret_x - viewport_width), 0, limit)
}

active :: proc(state: ^State) -> bool {
	return state != nil && state.window_id != 0 && state.buttons != {}
}

cancel :: proc(state: ^State) {
	if state != nil {
		state^ = {}
	}
}

position_fraction :: proc(track: layout.Rect, pos: coords.Logical_Point) -> f32 {
	if track.height <= 0 {
		return 0
	}
	return clamp((pos.y - track.y) / track.height, 0, 1)
}

repeat_interval :: proc(fraction: f32) -> u64 {
	bounded := clamp(fraction, 0, 1)
	return MAX_REPEAT_MS - u64(bounded * f32(MAX_REPEAT_MS - MIN_REPEAT_MS))
}

down :: proc(state: ^State, window_id: layout.Window_ID, button: input.Mouse_Button, pos: coords.Logical_Point, track: layout.Rect, now_ms: u64, on_thumb := true) -> Action {
	was_active := active(state)
	cancel(state)
	if was_active || window_id == 0 || !layout.contains(track, pos) {
		return {}
	}
	fraction := position_fraction(track, pos)
	state^ = {window_id = window_id, buttons = {button}, track = track, position = fraction}
	if !on_thumb {
		return {window_id = window_id, kind = .Absolute, fraction = fraction}
	}
	switch button {
	case .Left:
		state.next_repeat_ms = now_ms + repeat_interval(fraction)
		return {window_id = window_id, kind = .Relative, delta = -1}
	case .Middle:
		return {window_id = window_id, kind = .Absolute, fraction = fraction}
	case .Right:
		state.next_repeat_ms = now_ms + repeat_interval(fraction)
		return {window_id = window_id, kind = .Relative, delta = 1}
	}
	cancel(state)
	return {}
}

move :: proc(state: ^State, pos: coords.Logical_Point, buttons: input.Mouse_Buttons) -> Action {
	if !active(state) {
		return {}
	}
	if buttons != state.buttons || math.is_nan(pos.x) || math.is_inf(pos.x) || math.is_nan(pos.y) || math.is_inf(pos.y) {
		cancel(state)
		return {}
	}
	fraction := position_fraction(state.track, pos)
	if fraction == state.position {
		return {}
	}
	state.position = fraction
	state.next_repeat_ms = 0
	return {window_id = state.window_id, kind = .Absolute, fraction = fraction}
}

up :: proc(state: ^State, button: input.Mouse_Button) {
	if active(state) && button in state.buttons {
		cancel(state)
	}
}

repeat :: proc(state: ^State, now_ms: u64) -> Action {
	if !active(state) || state.next_repeat_ms == 0 || now_ms < state.next_repeat_ms {
		return {}
	}
	delta := 0
	if .Left in state.buttons {
		delta = -1
	} else if .Right in state.buttons {
		delta = 1
	}
	if delta == 0 {
		return {}
	}
	state.next_repeat_ms = now_ms + repeat_interval(state.position)
	return {window_id = state.window_id, kind = .Relative, delta = delta}
}
