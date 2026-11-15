package keybind_test

import "core:testing"

import editing "hammer:core/editing"
import input "hammer:core/input"
import keybind "hammer:core/keybind"

expect_action :: proc(t: ^testing.T, event: input.Key_Down, want: keybind.Action, has_selection := false) {
	_ = has_selection
	got, ok := keybind.resolve(event)
	testing.expectf(t, ok, "%v: expected an action", event)
	testing.expectf(t, got == want, "%v: got %v, want %v", event, got, want)
}

expect_unbound :: proc(t: ^testing.T, event: input.Key_Down, has_selection := false) {
	_ = has_selection
	got, ok := keybind.resolve(event)
	testing.expectf(t, !ok, "%v: unexpectedly resolved to %v", event, got)
}

@(test)
test_plain_and_shift_movement :: proc(t: ^testing.T) {
	cases := []struct {
		key:    input.Key,
		mods:   input.Modifiers,
		motion: editing.Motion,
		extend: bool
	} {
		{key = .Left, motion = .Grapheme_Left},
		{key = .Right, motion = .Grapheme_Right},
		{key = .Up, motion = .Line_Up},
		{key = .Down, motion = .Line_Down},
		{key = .Home, motion = .Line_Start},
		{key = .End, motion = .Line_End},
		{key = .Left, mods = {.Shift}, motion = .Grapheme_Left, extend = true},
		{key = .Right, mods = {.Shift}, motion = .Grapheme_Right, extend = true},
		{key = .Up, mods = {.Shift}, motion = .Line_Up, extend = true},
		{key = .Down, mods = {.Shift}, motion = .Line_Down, extend = true},
		{key = .Home, mods = {.Shift}, motion = .Line_Start, extend = true},
		{key = .End, mods = {.Shift}, motion = .Line_End, extend = true},
	}
	for c in cases {
		expect_action(
			t,
			{key = c.key, modifiers = c.mods},
			editing.Move{motion = c.motion, extend = c.extend},
		)
	}
}

@(test)
test_ctrl_movement_and_selection :: proc(t: ^testing.T) {
	cases := []struct {
		key:    input.Key,
		motion: editing.Motion,
	} {
		{key = .Left, motion = .Word_Left},
		{key = .Right, motion = .Word_Right},
		{key = .Home, motion = .Document_Start},
		{key = .End, motion = .Document_End},
	}
	extension_modes := []bool{false, true}
	for c in cases {
		for extend in extension_modes {
			mods := input.Modifiers{.Ctrl}
			if extend {
				mods += {.Shift}
			}
			expect_action(
				t,
				{key = c.key, modifiers = mods},
				editing.Move{motion = c.motion, extend = extend},
			)
		}
	}
	expect_unbound(t, {key = .Up, modifiers = {.Ctrl}})
	expect_unbound(t, {key = .Down, modifiers = {.Ctrl, .Shift}})
}

@(test)
test_modern_command_defaults :: proc(t: ^testing.T) {
	for binding in keybind.DEFAULT_COMMAND_BINDINGS {
		expect_action(t, {key = binding.key, modifiers = binding.modifiers}, binding.action)
	}
}

@(test)
test_repeat_policy :: proc(t: ^testing.T) {
	expect_action(
		t,
		{key = .Left, repeat = true},
		editing.Move{motion = .Grapheme_Left},
	)
	expect_action(
		t,
		{key = .Down, modifiers = {.Shift}, repeat = true},
		editing.Move{motion = .Line_Down, extend = true},
	)
	expect_action(
		t,
		{key = .End, modifiers = {.Ctrl}, repeat = true},
		editing.Move{motion = .Document_End},
	)
	for binding in keybind.DEFAULT_COMMAND_BINDINGS {
		expect_unbound(t, {key = binding.key, modifiers = binding.modifiers, repeat = true})
	}
	expect_unbound(t, {key = .Tab, repeat = true}, true)
	expect_unbound(t, {key = .Tab, modifiers = {.Shift}, repeat = true}, true)
}

@(test)
test_altgr_never_resolves_commands :: proc(t: ^testing.T) {
	keys := []input.Key{.A, .C, .V, .X, .Z, .S, .Left, .Right, .Home, .End, .Enter}
	for key in keys {
		expect_unbound(t, {key = key, modifiers = {.Ctrl, .Alt}}, true)
		expect_unbound(t, {key = key, modifiers = {.Ctrl, .Alt, .Shift}}, true)
	}
}

@(test)
test_tab_is_independent_of_selection :: proc(t: ^testing.T) {
	expect_action(t, {key = .Tab}, keybind.Indent{}, true)
	expect_action(t, {key = .Tab}, keybind.Indent{}, false)
	expect_action(t, {key = .Tab, modifiers = {.Shift}}, keybind.Outdent{}, false)
	expect_action(t, {key = .Tab, modifiers = {.Shift}}, keybind.Outdent{}, true)
	expect_unbound(t, {key = .Tab, modifiers = {.Ctrl}}, true)
	expect_unbound(t, {key = .Tab, modifiers = {.Alt}}, true)
}

@(test)
test_unbound_and_exact_modifier_matching :: proc(t: ^testing.T) {
	cases := []input.Key_Down {
		{key = .Invalid},
		{key = .Escape},
		{key = .Enter},
		{key = .Enter, modifiers = {.Shift}},
		{key = .A},
		{key = .B, modifiers = {.Ctrl}},
		{key = .C, modifiers = {.Ctrl, .Shift}},
		{key = .C, modifiers = {.Alt}},
		{key = .C, modifiers = {.Super}},
		{key = .Left, modifiers = {.Alt}},
		{key = .Left, modifiers = {.Super}},
		{key = .Enter, modifiers = {.Ctrl, .Shift}},
		{key = .Enter, modifiers = {.Alt, .Shift}},
	}
	for event in cases {
		expect_unbound(t, event, true)
	}
}
