package mouse

import "core:math"

import coords "../coords"
import input "../input"

DOUBLE_CLICK_MS :: u64(500)
DEFAULT_DRAG_THRESHOLD :: f32(3)

Target_ID :: distinct u64

Mode :: enum u8 {
	None,
	Select,
	Execute,
	Look,
}

Chord :: enum u8 {
	None,
	Cut,
	Paste,
}

Click :: struct {
	target: Target_ID,
	offset: int,
	time_ms: u64,
	valid: bool,
}

State :: struct {
	mode: Mode,
	target: Target_ID,
	anchor: int,
	active: int,
	origin: coords.Logical_Point,
	buttons: input.Mouse_Buttons,
	modifiers: input.Modifiers,
	moved: bool,
	chorded: bool,
	canceled: bool,
	with_argument: bool,
	chord: Chord,
	last_click: Click,
	drag_threshold: f32,
}

Select_Start :: struct {
	target: Target_ID,
	offset: int,
	extend: bool,
	expand: bool,
}

Select_Update :: struct {
	target: Target_ID,
	offset: int,
	drag_started: bool,
}

Select_Finish :: struct {
	target: Target_ID,
	anchor: int,
	active: int,
	chorded: bool,
}

Execute :: struct {
	target: Target_ID,
	anchor: int,
	active: int,
	with_argument: bool,
}

Look :: struct {
	target: Target_ID,
	anchor: int,
	active: int,
	reverse: bool,
}

Chord_Cut :: struct {
	target: Target_ID,
}

Chord_Paste :: struct {
	target: Target_ID,
}

Undo_Cut :: struct {
	target: Target_ID,
}

Undo_Paste :: struct {
	target: Target_ID,
}

Cancel :: struct {
	target: Target_ID,
}

Action :: union {
	Select_Start,
	Select_Update,
	Select_Finish,
	Execute,
	Look,
	Chord_Cut,
	Chord_Paste,
	Undo_Cut,
	Undo_Paste,
	Cancel,
}

active :: proc(state: ^State) -> bool {
	return state != nil && state.buttons != {}
}

threshold :: proc(state: ^State) -> f32 {
	if state.drag_threshold > 0 && !math.is_nan(state.drag_threshold) && !math.is_inf(state.drag_threshold) {
		return state.drag_threshold
	}
	return DEFAULT_DRAG_THRESHOLD
}

reset_gesture :: proc(state: ^State, preserve_click: bool) {
	last_click := state.last_click
	drag_threshold := state.drag_threshold
	state^ = {drag_threshold = drag_threshold}
	if preserve_click {
		state.last_click = last_click
	}
}

cancel :: proc(state: ^State) {
	if state == nil {
		return
	}
	reset_gesture(state, false)
}

down :: proc(
	state: ^State,
	button: input.Mouse_Button,
	target: Target_ID,
	offset: int,
	pos: coords.Logical_Point,
	modifiers: input.Modifiers,
	now_ms: u64,
) -> Action {
	if state == nil || button in state.buttons {
		return {}
	}
	if state.buttons == {} {
		if target == 0 || offset < 0 || math.is_nan(pos.x) || math.is_nan(pos.y) || math.is_inf(pos.x) || math.is_inf(pos.y) {
			return {}
		}
		if button == .Left && modifiers != {} && modifiers != {.Shift} && modifiers != {.Ctrl} && modifiers != {.Alt} {
			return {}
		}
		reset_gesture(state, true)
		state.target = target
		state.anchor = offset
		state.active = offset
		state.origin = pos
		state.modifiers = modifiers
		state.buttons = {button}
		switch button {
		case .Left:
			if modifiers == {.Ctrl} {
				state.mode = .Execute
				return {}
			}
			if modifiers == {.Alt} {
				state.mode = .Look
				return {}
			}
			state.mode = .Select
			expand := .Shift not_in modifiers && state.last_click.valid &&
				state.last_click.target == target && state.last_click.offset == offset &&
				now_ms >= state.last_click.time_ms && now_ms - state.last_click.time_ms < DOUBLE_CLICK_MS
			if expand {
				state.last_click.valid = false
			}
			return Select_Start{target = target, offset = offset, extend = .Shift in modifiers, expand = expand}
		case .Middle:
			state.mode = .Execute
		case .Right:
			state.mode = .Look
		}
		return {}
	}

	state.buttons += {button}
	state.chorded = true
	if state.canceled {
		return {}
	}
	switch state.mode {
	case .None:
	case .Select:
		switch button {
		case .Left:
		case .Middle:
			if state.chord == .Paste {
				state.chord = .None
				return Undo_Paste{target = state.target}
			}
			if state.chord != .Cut {
				state.chord = .Cut
				return Chord_Cut{target = state.target}
			}
		case .Right:
			if state.chord == .Cut {
				state.chord = .None
				return Undo_Cut{target = state.target}
			}
			if state.chord != .Paste {
				state.chord = .Paste
				return Chord_Paste{target = state.target}
			}
		}
	case .Execute:
		if button == .Left {
			state.with_argument = true
		} else {
			state.canceled = true
		}
	case .Look:
		state.canceled = true
	}
	return {}
}

move :: proc(state: ^State, offset: int, pos: coords.Logical_Point, buttons: input.Mouse_Buttons) -> Action {
	if state == nil || state.buttons == {} {
		return {}
	}
	if offset < 0 || buttons != state.buttons || math.is_nan(pos.x) || math.is_nan(pos.y) || math.is_inf(pos.x) || math.is_inf(pos.y) {
		target := state.target
		cancel(state)
		return Cancel{target = target}
	}
	was_moved := state.moved
	drag_threshold := threshold(state)
	if abs(pos.x - state.origin.x) > drag_threshold || abs(pos.y - state.origin.y) > drag_threshold {
		state.moved = true
	}
	if state.canceled {
		return {}
	}
	if !state.chorded {
		state.active = offset
	}
	if state.mode == .Select && .Left in state.buttons {
		return Select_Update{target = state.target, offset = state.active, drag_started = !was_moved && state.moved}
	}
	return {}
}

up :: proc(state: ^State, button: input.Mouse_Button, offset: int, pos: coords.Logical_Point, now_ms: u64) -> Action {
	if state == nil || button not_in state.buttons || offset < 0 {
		return {}
	}
	drag_threshold := threshold(state)
	if abs(pos.x - state.origin.x) > drag_threshold || abs(pos.y - state.origin.y) > drag_threshold {
		state.moved = true
	}
	if !state.chorded {
		state.active = offset
	}
	state.buttons -= {button}

	action: Action
	if state.mode == .Select && button == .Left {
		action = Select_Finish{target = state.target, anchor = state.anchor, active = state.active, chorded = state.chorded}
		if !state.chorded && !state.moved {
			state.last_click = {target = state.target, offset = state.active, time_ms = now_ms, valid = true}
		} else {
			state.last_click.valid = false
		}
		state.canceled = true
	}
	if state.buttons == {} {
		if !state.canceled {
			switch state.mode {
			case .None, .Select:
			case .Execute:
				action = Execute{
					target = state.target,
					anchor = state.anchor,
					active = state.active,
					with_argument = state.with_argument,
				}
			case .Look:
				action = Look{
					target = state.target,
					anchor = state.anchor,
					active = state.active,
					reverse = .Shift in state.modifiers,
				}
			}
		}
		reset_gesture(state, true)
	}
	return action
}
