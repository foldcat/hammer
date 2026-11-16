// Package keybind resolves normalized input facts into semantic editor actions
// (M06.02–M06.14). It separates committed text from commands but does not execute actions.
package keybind

import "core:math"

import editing "../editing"
import input "../input"

Copy :: struct {}
Cut :: struct {}
Paste :: struct {}
Undo :: struct {}
Redo :: struct {}
Save :: struct {}
Save_As :: struct {}
Find :: struct {}
Open_Finder :: struct {}
Close_Window :: struct {}
Request_Quit :: struct {}
Indent :: struct {}
Outdent :: struct {}
Execute_Text :: struct {}
Look_Text :: struct {}
Zoom_In :: struct {}
Zoom_Out :: struct {}
Zoom_Reset :: struct {}

// Action is the shared result of keyboard and zoom-scroll resolution.
// Movement/select-all values can be passed directly to editing.perform; the
// remaining actions are consumed by their owning subsystems.
Action :: union {
	editing.Move,
	editing.Select_All,
	Copy,
	Cut,
	Paste,
	Undo,
	Redo,
	Save,
	Save_As,
	Find,
	Open_Finder,
	Close_Window,
	Request_Quit,
	Indent,
	Outdent,
	Execute_Text,
	Look_Text,
	Zoom_In,
	Zoom_Out,
	Zoom_Reset,
	editing.Insert_Text,
	editing.Commit_Text,
	editing.Delete_Backward,
	editing.Delete_Word_Backward,
	editing.Delete_Forward,
}

Command_Binding :: struct {
	key:       input.Key,
	modifiers: input.Modifiers,
	action:    Action,
}

DEFAULT_COMMAND_BINDINGS :: []Command_Binding {
	{key = .C, modifiers = {.Ctrl}, action = Copy{}},
	{key = .C, modifiers = {.Ctrl, .Shift}, action = Copy{}},
	{key = .X, modifiers = {.Ctrl}, action = Cut{}},
	{key = .V, modifiers = {.Ctrl}, action = Paste{}},
	{key = .V, modifiers = {.Ctrl, .Shift}, action = Paste{}},
	{key = .Z, modifiers = {.Ctrl}, action = Undo{}},
	{key = .Z, modifiers = {.Ctrl, .Shift}, action = Redo{}},
	{key = .Y, modifiers = {.Ctrl}, action = Redo{}},
	{key = .A, modifiers = {.Ctrl}, action = editing.Select_All{}},
	{key = .S, modifiers = {.Ctrl}, action = Save{}},
	{key = .S, modifiers = {.Ctrl, .Shift}, action = Save_As{}},
	{key = .F, modifiers = {.Ctrl}, action = Find{}},
	{key = .P, modifiers = {.Ctrl}, action = Open_Finder{}},
	{key = .W, modifiers = {.Ctrl}, action = Close_Window{}},
	{key = .Q, modifiers = {.Ctrl}, action = Request_Quit{}},
	{key = .Enter, modifiers = {.Ctrl}, action = Execute_Text{}},
	{key = .Enter, modifiers = {.Alt}, action = Look_Text{}},
	{key = .Equal, modifiers = {.Ctrl}, action = Zoom_In{}},
	{key = .Equal, modifiers = {.Ctrl, .Shift}, action = Zoom_In{}},
	{key = .KP_Add, modifiers = {.Ctrl}, action = Zoom_In{}},
	{key = .Minus, modifiers = {.Ctrl}, action = Zoom_Out{}},
	{key = .KP_Subtract, modifiers = {.Ctrl}, action = Zoom_Out{}},
	{key = .D0, modifiers = {.Ctrl}, action = Zoom_Reset{}},
	{key = .KP_0, modifiers = {.Ctrl}, action = Zoom_Reset{}},
}

// resolve maps one normalized key-down event to an action. Tab always resolves
// to Indent so the consumer can apply the buffer's effective tabs/spaces setting.
// Movement is repeatable; commands and selection-all ignore auto-repeat.
// Ctrl+Alt is always unbound so AltGr text cannot trigger a command.
resolve :: proc(event: input.Key_Down) -> (Action, bool) {
	if .Ctrl in event.modifiers && .Alt in event.modifiers {
		return {}, false
	}
	if action, ok := resolve_movement(event.key, event.modifiers); ok {
		return action, true
	}
	if event.repeat {
		return {}, false
	}

	if event.key == .Tab && event.modifiers == {.Shift} {
		return Outdent{}, true
	}
	if event.key == .Tab && event.modifiers == {} {
		return Indent{}, true
	}
	for binding in DEFAULT_COMMAND_BINDINGS {
		if event.key == binding.key && event.modifiers == binding.modifiers {
			return binding.action, true
		}
	}
	return {}, false
}

resolve_movement :: proc(key: input.Key, modifiers: input.Modifiers) -> (Action, bool) {
	if .Alt in modifiers || .Super in modifiers {
		return {}, false
	}
	extend := .Shift in modifiers
	ctrl := .Ctrl in modifiers

	#partial switch key {
	case .Left, .Right:
		motion := editing.Motion.Grapheme_Left
		if key == .Right {
			motion = .Grapheme_Right
		}
		if ctrl {
			motion = .Word_Left if key == .Left else .Word_Right
		}
		return editing.Move{motion = motion, extend = extend}, true
	case .Up, .Down:
		if ctrl {
			return {}, false
		}
		motion := editing.Motion.Line_Up
		if key == .Down {
			motion = .Line_Down
		}
		return editing.Move{motion = motion, extend = extend}, true
	case .Home, .End:
		motion := editing.Motion.Line_Start
		if key == .End {
			motion = .Line_End
		}
		if ctrl {
			motion = .Document_Start if key == .Home else .Document_End
		}
		return editing.Move{motion = motion, extend = extend}, true
	case:
	}
	return {}, false
}


// resolve_event separates committed text from key commands and Ctrl+wheel zoom.
// Printable Text and IME commits are inserted only with no command modifiers or
// with Ctrl+Alt (AltGr). Control scalars are handled as key-down edits instead,
// preventing Enter or Tab from being applied once as a command and again as text.
resolve_event :: proc(event: input.Event) -> (Action, bool) {
	#partial switch e in event {
	case input.Key_Down:
		if action, ok := resolve(e); ok {
			return action, true
		}
		if e.key == .Backspace {
			if .Super in e.modifiers || (.Ctrl in e.modifiers && .Alt in e.modifiers) {
				return {}, false
			}
			if .Alt in e.modifiers {
				return editing.Delete_Word_Backward{}, true
			}
			return editing.Delete_Backward{}, true
		}
		if e.modifiers != {} {
			return {}, false
		}
		#partial switch e.key {
		case .Delete:
			return editing.Delete_Forward{}, true
		case .Enter, .KP_Enter:
			return editing.Insert_Text{text = '\n'}, true
		case:
		}
	case input.Scroll:
		if e.modifiers == {.Ctrl} && e.dy != 0 && !math.is_nan(e.dy) && !math.is_inf(e.dy) {
			if e.dy < 0 {
				return Zoom_In{}, true
			}
			return Zoom_Out{}, true
		}
	case input.Text:
		if e.text < 0x20 || e.text >= 0x7f && e.text <= 0x9f {
			return {}, false
		}
		if !text_modifiers_allowed(e.modifiers) {
			return {}, false
		}
		return editing.Insert_Text{text = e.text}, true
	case input.Commit_Text:
		if e.text == "" || !text_modifiers_allowed(e.modifiers) {
			return {}, false
		}
		for r in e.text {
			if r < 0x20 || r >= 0x7f && r <= 0x9f {
				return {}, false
			}
		}
		return editing.Commit_Text{text = e.text}, true
	case:
	}
	return {}, false
}

text_modifiers_allowed :: proc(modifiers: input.Modifiers) -> bool {
	ctrl := .Ctrl in modifiers
	alt := .Alt in modifiers
	altgr := ctrl && alt && .Super not_in modifiers
	return altgr || (!ctrl && !alt && .Super not_in modifiers)
}
