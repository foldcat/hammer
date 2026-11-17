package mouse_test

import "core:testing"

import coords "hammer:core/coords"
import mouse "hammer:core/mouse"

point :: proc(x: f32 = 10, y: f32 = 10) -> coords.Logical_Point {
	return {x, y}
}

@(test)
test_select_double_click_and_cut_snarf :: proc(t: ^testing.T) {
	state: mouse.State
	action := mouse.down(&state, .Left, 1, 2, point(), {}, 100)
	start, ok := action.(mouse.Select_Start)
	testing.expect(t, ok && !start.expand)
	action = mouse.up(&state, .Left, 2, point(), 110)
	_, ok = action.(mouse.Select_Finish)
	testing.expect(t, ok)

	action = mouse.down(&state, .Left, 1, 2, point(), {}, 300)
	start, ok = action.(mouse.Select_Start)
	testing.expect(t, ok && start.expand)
	action = mouse.down(&state, .Middle, 0, 0, point(), {}, 310)
	_, ok = action.(mouse.Chord_Cut)
	testing.expect(t, ok)
	action = mouse.down(&state, .Right, 0, 0, point(), {}, 320)
	_, ok = action.(mouse.Undo_Cut)
	testing.expect(t, ok)
	mouse.up(&state, .Right, 2, point(), 330)
	mouse.up(&state, .Middle, 2, point(), 340)
	action = mouse.up(&state, .Left, 2, point(), 350)
	finish, finish_ok := action.(mouse.Select_Finish)
	testing.expect(t, finish_ok && finish.chorded)
	testing.expect(t, !mouse.active(&state))
}

@(test)
test_paste_reversed_by_cut :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Left, 7, 4, point(), {}, 0)
	action := mouse.down(&state, .Right, 0, 0, point(), {}, 1)
	_, ok := action.(mouse.Chord_Paste)
	testing.expect(t, ok)
	action = mouse.down(&state, .Middle, 0, 0, point(), {}, 2)
	_, ok = action.(mouse.Undo_Paste)
	testing.expect(t, ok)
	mouse.up(&state, .Middle, 4, point(), 3)
	mouse.up(&state, .Right, 4, point(), 4)
	mouse.up(&state, .Left, 4, point(), 5)
	testing.expect(t, !mouse.active(&state))
}

@(test)
test_execute_drag_and_argument_chord :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Middle, 3, 2, point(), {}, 0)
	mouse.move(&state, 8, point(30), {.Middle})
	action := mouse.up(&state, .Middle, 8, point(30), 1)
	execute, ok := action.(mouse.Execute)
	testing.expect(t, ok && execute.anchor == 2 && execute.active == 8 && !execute.with_argument)

	mouse.down(&state, .Middle, 3, 2, point(), {}, 10)
	mouse.down(&state, .Left, 0, 0, point(), {}, 11)
	mouse.up(&state, .Middle, 2, point(), 12)
	action = mouse.up(&state, .Left, 2, point(), 13)
	execute, ok = action.(mouse.Execute)
	testing.expect(t, ok && execute.with_argument && execute.anchor == execute.active)
}

@(test)
test_execute_and_lookup_cancellation :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Middle, 3, 2, point(), {}, 0)
	mouse.down(&state, .Right, 0, 0, point(), {}, 1)
	mouse.up(&state, .Right, 2, point(), 2)
	action := mouse.up(&state, .Middle, 2, point(), 3)
	_, ok := action.(mouse.Execute)
	testing.expect(t, !ok && !mouse.active(&state))

	mouse.down(&state, .Right, 3, 2, point(), {.Shift}, 10)
	mouse.down(&state, .Left, 0, 0, point(), {}, 11)
	mouse.up(&state, .Left, 2, point(), 12)
	action = mouse.up(&state, .Right, 2, point(), 13)
	_, ok = action.(mouse.Look)
	testing.expect(t, !ok)
}

@(test)
test_reverse_lookup_and_lost_capture :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Right, 9, 4, point(), {.Shift}, 0)
	action := mouse.up(&state, .Right, 6, point(20), 1)
	look, ok := action.(mouse.Look)
	testing.expect(t, ok && look.reverse && look.active == 6)

	mouse.down(&state, .Left, 9, 4, point(), {}, 10)
	action = mouse.move(&state, 5, point(20), {})
	_, ok = action.(mouse.Cancel)
	testing.expect(t, ok && !mouse.active(&state))
	mouse.cancel(&state)
	testing.expect(t, !state.last_click.valid)
}
