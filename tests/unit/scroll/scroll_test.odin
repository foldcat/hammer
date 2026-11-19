package scroll_test

import "core:testing"

import layout "hammer:core/layout"
import scroll "hammer:core/scroll"

track_fixture :: proc() -> layout.Rect {
	return {x = 2, y = 60, width = 12, height = 300}
}

@(test)
test_body_rects_reserve_left_scrollbar :: proc(t: ^testing.T) {
	track, text := scroll.body_rects({x = 2, y = 60, width = 400, height = 300})
	testing.expect(t, track == layout.Rect{x = 2, y = 60, width = 12, height = 300})
	testing.expect(t, text == layout.Rect{x = 14, y = 60, width = 388, height = 300})
	track, text = scroll.body_rects({width = 8, height = 20})
	testing.expect(t, track.width == 8 && text.x == 8 && text.width == 0)
}

@(test)
test_thumb_is_bounded_and_reacts_to_origin_and_viewport :: proc(t: ^testing.T) {
	track := track_fixture()
	full := scroll.thumb_rect(track, 0, 0, 1, 20, 20)
	testing.expect(t, full == track)
	initial := scroll.thumb_rect(track, 0, 0, 1, 100, 20)
	middle := scroll.thumb_rect(track, 50, 1, 2, 100, 20)
	last := scroll.thumb_rect(track, 99, 0, 1, 100, 20)
	testing.expect(t, initial.y == track.y && initial.height == 60)
	testing.expect(t, middle.y > initial.y && middle.y < last.y)
	testing.expect(t, last.y + last.height == track.y + track.height)
	resized := track
	resized.height = 120
	small := scroll.thumb_rect(resized, 99, 0, 1, 100, 2)
	testing.expect(t, small.height >= scroll.MIN_THUMB_HEIGHT)
	testing.expect(t, small.y + small.height == resized.y + resized.height)
}

@(test)
test_buttons_scroll_immediately_and_middle_jumps :: proc(t: ^testing.T) {
	state: scroll.State
	track := track_fixture()
	action := scroll.down(&state, 7, .Right, {x = 4, y = 70}, track, 100)
	testing.expect(t, action.window_id == 7 && action.kind == .Relative && action.delta == 1)
	testing.expect(t, scroll.active(&state))
	testing.expect(t, scroll.repeat(&state, 200).delta == 0)
	action = scroll.repeat(&state, 400)
	testing.expect(t, action.delta == 1)
	scroll.up(&state, .Right)
	testing.expect(t, !scroll.active(&state))

	action = scroll.down(&state, 7, .Left, {x = 4, y = 70}, track, 500)
	testing.expect(t, action.delta == -1)
	scroll.up(&state, .Left)
	action = scroll.down(&state, 7, .Middle, {x = 4, y = 210}, track, 600)
	testing.expect(t, action.kind == .Absolute && action.fraction == 0.5)
	testing.expect(t, scroll.absolute_line(action.fraction, 101) == 50)
	testing.expect(t, scroll.repeat(&state, 1000).window_id == 0)
	scroll.up(&state, .Middle)
}

@(test)
test_drag_follows_pointer_and_disables_repeat :: proc(t: ^testing.T) {
	state: scroll.State
	track := track_fixture()
	scroll.down(&state, 7, .Right, {x = 4, y = 70}, track, 100)
	action := scroll.move(&state, {x = 4, y = 210}, {.Right})
	testing.expect(t, action.window_id == 7 && action.kind == .Absolute && action.fraction == 0.5)
	testing.expect(t, state.next_repeat_ms == 0)
	testing.expect(t, scroll.repeat(&state, 1000).window_id == 0)
	action = scroll.move(&state, {x = 4, y = 210}, {.Right})
	testing.expect(t, action.window_id == 0)
	scroll.up(&state, .Right)
	testing.expect(t, !scroll.active(&state))

	action = scroll.down(&state, 7, .Right, {x = 4, y = 210}, track, 200, false)
	testing.expect(t, action.kind == .Absolute && action.fraction == 0.5)
	testing.expect(t, state.next_repeat_ms == 0)
	scroll.up(&state, .Right)
}

@(test)
test_holding_lower_repeats_faster_and_outside_drag_continues :: proc(t: ^testing.T) {
	track := track_fixture()
	high, low: scroll.State
	scroll.down(&high, 1, .Right, {x = 4, y = 65}, track, 0)
	scroll.down(&low, 1, .Right, {x = 4, y = 355}, track, 0)
	testing.expect(t, low.next_repeat_ms < high.next_repeat_ms)
	scroll.move(&low, {x = 4, y = 100}, {})
	testing.expect(t, !scroll.active(&low))
	action := scroll.move(&high, {x = 100, y = 400}, {.Right})
	testing.expect(t, scroll.active(&high))
	testing.expect(t, action.kind == .Absolute && action.fraction == 1)
	scroll.up(&high, .Right)
	testing.expect(t, !scroll.active(&high))
}

@(test)
test_right_motion_reveals_caret_past_right_edge :: proc(t: ^testing.T) {
	testing.expect(t, scroll.reveal_caret_right(12, 50, 100, 1024) == 12)
	testing.expect(t, scroll.reveal_caret_right(0, 100, 40, 1024) == 60)
	testing.expect(t, scroll.reveal_caret_right(80, 100, 40, 1024) == 80)
	testing.expect(t, scroll.reveal_caret_right(0, 200, 40, 100) == 100)
	testing.expect(t, scroll.reveal_caret_right(20, 100, 0, 1024) == 20)
}

@(test)
test_invalid_geometry_and_second_button_do_not_start_gestures :: proc(t: ^testing.T) {
	state: scroll.State
	track := track_fixture()
	action := scroll.down(&state, 1, .Right, {x = 30, y = 70}, track, 0)
	testing.expect(t, action.window_id == 0 && !scroll.active(&state))
	scroll.down(&state, 1, .Right, {x = 4, y = 70}, track, 0)
	action = scroll.down(&state, 1, .Middle, {x = 4, y = 70}, track, 1)
	testing.expect(t, action.window_id == 0 && !scroll.active(&state))
	testing.expect(t, scroll.absolute_line(0, 0) == 0)
}
