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
test_middle_click_tolerance_and_drag_highlight :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Middle, 3, 2, point(), {}, 0)
	action := mouse.move(&state, 3, point(11), {.Middle})
	testing.expect(t, action == nil)
	action = mouse.up(&state, .Middle, 3, point(11), 1)
	execute, ok := action.(mouse.Execute)
	testing.expect(t, ok && execute.anchor == 2 && execute.active == 2)

	mouse.down(&state, .Middle, 3, 2, point(), {}, 10)
	action = mouse.move(&state, 8, point(30), {.Middle})
	update, update_ok := action.(mouse.Execute_Update)
	testing.expect(t, update_ok && update.anchor == 2 && update.active == 8)
	action = mouse.up(&state, .Middle, 8, point(30), 11)
	execute, ok = action.(mouse.Execute)
	testing.expect(t, ok && execute.anchor == 2 && execute.active == 8)
}

@(test)
test_double_click_ignores_subthreshold_motion :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Left, 1, 2, point(), {}, 100)
	mouse.up(&state, .Left, 2, point(), 110)
	action := mouse.down(&state, .Left, 1, 2, point(), {}, 300)
	start, ok := action.(mouse.Select_Start)
	testing.expect(t, ok && start.expand)
	action = mouse.move(&state, 3, point(11), {.Left})
	testing.expect(t, action == nil)
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


@(test)
test_modified_primary_execute_and_look_do_not_select :: proc(t: ^testing.T) {
	state: mouse.State
	action := mouse.down(&state, .Left, 3, 2, point(), {.Ctrl}, 0)
	_, selected := action.(mouse.Select_Start)
	testing.expect(t, !selected && mouse.active(&state))
	mouse.move(&state, 8, point(30), {.Left})
	action = mouse.up(&state, .Left, 8, point(30), 1)
	execute, execute_ok := action.(mouse.Execute)
	testing.expect(t, execute_ok && execute.anchor == 2 && execute.active == 8 && !execute.with_argument)

	action = mouse.down(&state, .Left, 9, 4, point(), {.Alt}, 10)
	_, selected = action.(mouse.Select_Start)
	testing.expect(t, !selected && mouse.active(&state))
	action = mouse.up(&state, .Left, 6, point(20), 11)
	look, look_ok := action.(mouse.Look)
	testing.expect(t, look_ok && look.anchor == 4 && look.active == 6 && !look.reverse)
}

@(test)
test_modified_primary_rejects_altgr_and_cancels_on_lost_capture :: proc(t: ^testing.T) {
	state: mouse.State
	action := mouse.down(&state, .Left, 3, 2, point(), {.Ctrl, .Alt}, 0)
	testing.expect(t, action == nil && !mouse.active(&state))
	action = mouse.down(&state, .Left, 3, 2, point(), {.Ctrl, .Shift}, 1)
	testing.expect(t, action == nil && !mouse.active(&state))
	action = mouse.down(&state, .Left, 3, 2, point(), {.Alt, .Shift}, 2)
	testing.expect(t, action == nil && !mouse.active(&state))
	action = mouse.down(&state, .Left, 3, 2, point(), {.Super}, 3)
	testing.expect(t, action == nil && !mouse.active(&state))

	mouse.down(&state, .Left, 3, 2, point(), {.Ctrl}, 10)
	action = mouse.move(&state, 5, point(20), {})
	_, canceled := action.(mouse.Cancel)
	testing.expect(t, canceled && !mouse.active(&state))
	action = mouse.up(&state, .Left, 5, point(20), 11)
	testing.expect(t, action == nil)
}

@(test)
test_modifier_chord_cut_and_snarf :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Left, 1, 2, point(), {}, 100)
	action := mouse.modifier_down(&state, .Middle)
	_, ok := action.(mouse.Chord_Cut)
	testing.expect(t, ok)
	action = mouse.modifier_down(&state, .Right)
	_, ok = action.(mouse.Undo_Cut)
	testing.expect(t, ok)
	action = mouse.up(&state, .Left, 2, point(), 200)
	finish, finish_ok := action.(mouse.Select_Finish)
	testing.expect(t, finish_ok && finish.chorded)
	testing.expect(t, !mouse.active(&state))
}

@(test)
test_modifier_chord_paste_reversed_by_cut :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Left, 7, 4, point(), {}, 0)
	action := mouse.modifier_down(&state, .Right)
	_, ok := action.(mouse.Chord_Paste)
	testing.expect(t, ok)
	action = mouse.modifier_down(&state, .Middle)
	_, ok = action.(mouse.Undo_Paste)
	testing.expect(t, ok)
	mouse.up(&state, .Left, 4, point(), 1)
	testing.expect(t, !mouse.active(&state))
}

@(test)
test_modifier_chord_requires_held_button :: proc(t: ^testing.T) {
	state: mouse.State
	testing.expect(t, mouse.modifier_down(&state, .Middle) == nil)
	testing.expect(t, mouse.modifier_down(&state, .Right) == nil)
	testing.expect(t, !mouse.active(&state))
}

@(test)
test_modifier_chord_ignores_non_select_modes :: proc(t: ^testing.T) {
	state: mouse.State
	mouse.down(&state, .Left, 3, 2, point(), {.Ctrl}, 0)
	testing.expect(t, state.mode == .Execute)
	testing.expect(t, mouse.modifier_down(&state, .Right) == nil)
	testing.expect(t, !state.canceled)
	mouse.up(&state, .Left, 2, point(), 1)

	look: mouse.State
	mouse.down(&look, .Left, 3, 2, point(), {.Alt}, 10)
	testing.expect(t, look.mode == .Look)
	testing.expect(t, mouse.modifier_down(&look, .Middle) == nil)
	testing.expect(t, !look.canceled)
	mouse.up(&look, .Left, 2, point(), 11)
}
