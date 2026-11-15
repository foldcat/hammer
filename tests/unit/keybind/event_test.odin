package keybind_test

import "core:testing"

import editing "hammer:core/editing"
import input "hammer:core/input"
import keybind "hammer:core/keybind"

expect_event_action :: proc(t: ^testing.T, event: input.Event, want: keybind.Action, has_selection := false) {
	_ = has_selection
	got, ok := keybind.resolve_event(event)
	testing.expectf(t, ok, "%v: expected an action", event)
	testing.expectf(t, got == want, "%v: got %v, want %v", event, got, want)
}

expect_event_unbound :: proc(t: ^testing.T, event: input.Event, has_selection := false) {
	_ = has_selection
	got, ok := keybind.resolve_event(event)
	testing.expectf(t, !ok, "%v: unexpectedly resolved to %v", event, got)
}

@(test)
test_committed_text_and_altgr_insert :: proc(t: ^testing.T) {
	cases := []input.Text {
		{text = 'a'},
		{text = ' ', modifiers = {.Shift}},
		{text = '中'},
		{text = '😀'},
		{text = '@', modifiers = {.Ctrl, .Alt}},
		{text = '€', modifiers = {.Ctrl, .Alt, .Shift}},
	}
	for event in cases {
		expect_event_action(t, event, editing.Insert_Text{text = event.text})
	}
}

@(test)
test_command_modifiers_and_control_text_do_not_insert :: proc(t: ^testing.T) {
	modifiers := []input.Modifiers{{.Ctrl}, {.Alt}, {.Super}, {.Ctrl, .Shift}, {.Alt, .Shift}, {.Ctrl, .Alt, .Super}}
	for mods in modifiers {
		expect_event_unbound(t, input.Text{text = 'c', modifiers = mods})
	}
	controls := []rune{'\n', '\r', '\t', rune(1), rune(0x7f), rune(0x85)}
	for control in controls {
		expect_event_unbound(t, input.Text{text = control})
		expect_event_unbound(t, input.Text{text = control, modifiers = {.Ctrl, .Alt}})
	}
}

@(test)
test_special_editing_keys_are_key_down_actions :: proc(t: ^testing.T) {
	expect_event_action(t, input.Key_Down{key = .Backspace}, editing.Delete_Backward{})
	expect_event_action(t, input.Key_Down{key = .Delete}, editing.Delete_Forward{})
	expect_event_action(t, input.Key_Down{key = .Enter}, editing.Insert_Text{text = '\n'})
	expect_event_action(t, input.Key_Down{key = .KP_Enter}, editing.Insert_Text{text = '\n'})
	expect_event_action(t, input.Key_Down{key = .Tab}, keybind.Indent{})
	expect_event_action(t, input.Key_Down{key = .Backspace, repeat = true}, editing.Delete_Backward{})
	expect_event_action(t, input.Key_Down{key = .Enter, repeat = true}, editing.Insert_Text{text = '\n'})
	expect_event_unbound(t, input.Key_Down{key = .Tab, repeat = true})
	expect_event_unbound(t, input.Key_Down{key = .Tab, repeat = true}, true)
	expect_event_unbound(t, input.Key_Down{key = .Backspace, modifiers = {.Ctrl}})
	expect_event_unbound(t, input.Key_Down{key = .Enter, modifiers = {.Shift}})
	expect_event_unbound(t, input.Key_Down{key = .Tab, modifiers = {.Alt}})
}

@(test)
test_ime_commit_and_preedit_separation :: proc(t: ^testing.T) {
	expect_event_action(t, input.Commit_Text{text = "é中🙂"}, editing.Commit_Text{text = "é中🙂"})
	expect_event_action(
		t,
		input.Commit_Text{text = "@", modifiers = {.Ctrl, .Alt}},
		editing.Commit_Text{text = "@"},
	)
	expect_event_unbound(t, input.Commit_Text{text = "x", modifiers = {.Ctrl}})
	expect_event_unbound(t, input.Commit_Text{})
	controls := []string{"\t", "\r", "\n", "text\n"}
	for control in controls {
		expect_event_unbound(t, input.Commit_Text{text = control})
	}
	expect_event_unbound(t, input.Preedit{text = "中", caret = 1})
}

@(test)
test_non_input_events_are_ignored :: proc(t: ^testing.T) {
	expect_event_unbound(t, input.Key_Up{key = .A})
	expect_event_unbound(t, input.Pointer_Down{button = .Left})
	expect_event_unbound(t, input.Pointer_Move{})
	expect_event_unbound(t, input.Scroll{dy = 1})
}
