// Tests for the normalized input event package (M01.04):
// `hammer:core/input` — the backend-free editor event types, text
// (UTF-32) validation, and the stable diagnostic rendering the
// application layer logs.
package input_test

import "core:testing"

import coords "hammer:core/coords"
import errs "hammer:core/errs"
import input "hammer:core/input"

// test_normalize_text_valid covers the codepoints a backend CHAR
// event may deliver: ASCII, Latin-1, BMP, astral, and the top of the
// Unicode range.
@(test)
test_normalize_text_valid :: proc(t: ^testing.T) {
	cases := []struct {
		code: u32,
		want: rune,
	} {
		{0x20, ' '},
		{0x61, 'a'},
		{0x41, 'A'},
		{0xE9, 'é'},
		{0x4E2D, '中'},
		{0x1F600, '😀'},
		{0x10FFFF, 0x10FFFF},
	}
	for c in cases {
		got, err := input.normalize_text(c.code)
		defer errs.destroy(&err)
		testing.expectf(t, errs.ok(err), "U+%X: unexpected error %v", c.code, errs.describe(err))
		testing.expectf(t, got == c.want, "U+%X: got U+%X, want U+%X", c.code, u32(got), u32(c.want))
	}
}

// test_normalize_text_invalid covers the rejected backend codes:
// NUL, UTF-16 surrogate halves, beyond U+10FFFF, and 32-bit garbage.
// Backend input is external data; it must be rejected as a value
// error, never asserted on.
@(test)
test_normalize_text_invalid :: proc(t: ^testing.T) {
	bad_codes := []u32{0, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0x110000, 0xFFFFFFFF}
	for code in bad_codes {
		got, err := input.normalize_text(code)
		testing.expectf(t, !errs.ok(err), "U+%X: expected an error", code)
		testing.expectf(t, err.kind == .Invalid_Input, "U+%X: got kind %v", code, err.kind)
		testing.expect(t, got == 0, "expected a zero rune")
		errs.destroy(&err)
	}
}

// test_key_names_complete pins the diagnostic table: every Key
// member must have a non-empty name (a short table would panic the
// enum-indexed lookup, a long one would leave empty entries — both
// are caught here).
@(test)
test_key_names_complete :: proc(t: ^testing.T) {
	for k in input.Key {
		name := input.key_name(k)
		testing.expectf(t, name != "", "missing name for %v", k)
	}
	testing.expect(t, input.key_name(.Invalid) == "?")
	testing.expect(t, input.key_name(.Escape) == "ESCAPE")
	testing.expect(t, input.key_name(.A) == "A")
	testing.expect(t, input.key_name(.D7) == "7")
	testing.expect(t, input.key_name(.F25) == "F25")
	testing.expect(t, input.key_name(.KP_Equal) == "KP_EQUAL")
	testing.expect(t, input.key_name(.Right_Control) == "RIGHT_CONTROL")
}

// test_describe pins the stable diagnostic format the application
// layer logs; the headless input smoke greps these exact strings.
@(test)
test_describe :: proc(t: ^testing.T) {
	at := coords.Logical_Point{150, 100}
	expect_describe := proc(t: ^testing.T, e: input.Event, want: string) {
		testing.expectf(t, input.describe(e) == want, "describe: got %q, want %q", input.describe(e), want)
	}

	expect_describe(t, input.Key_Down{key = .Escape}, "key down ESCAPE")
	expect_describe(t, input.Key_Down{key = .A, modifiers = {.Shift}}, "key down A mods=SHIFT")
	expect_describe(t, input.Key_Down{key = .A, repeat = true}, "key down A (repeat)")
	expect_describe(t, input.Key_Down{key = .D1, modifiers = {.Ctrl, .Alt}}, "key down 1 mods=CTRL+ALT")
	expect_describe(t, input.Key_Up{key = .A}, "key up A")
	expect_describe(t, input.Text{text = 'a'}, "text 'a' (U+0061)")
	expect_describe(t, input.Text{text = '中'}, "text '中' (U+4E2D)")
	expect_describe(t, input.Text{text = 0x01}, "text U+0001")
	expect_describe(t, input.Text{text = ' ', modifiers = {.Shift}}, "text ' ' (U+0020) mods=SHIFT")
	expect_describe(t, input.Pointer_Down{button = .Left, pos = at}, "pointer down LEFT at 150,100")
	expect_describe(t, input.Pointer_Up{button = .Middle, pos = at}, "pointer up MIDDLE at 150,100")
	expect_describe(t, input.Pointer_Move{pos = at}, "move at 150,100")
	expect_describe(t, input.Pointer_Move{pos = at, buttons = {.Left}}, "move at 150,100 buttons=LEFT")
	expect_describe(t, input.Pointer_Move{pos = at, buttons = {.Left, .Right}}, "move at 150,100 buttons=LEFT+RIGHT")
	expect_describe(t, input.Scroll{pos = at, dx = 0, dy = -1}, "scroll dx=0 dy=-1 at 150,100")
	expect_describe(t, input.Scroll{pos = at, dy = 1, modifiers = {.Ctrl}}, "scroll dx=0 dy=1 at 150,100 mods=CTRL")
}

// test_event_union_roundtrip verifies the tagged union mechanics the
// consumers rely on: a type switch narrows to the exact variant and
// preserves every field.
@(test)
test_event_union_roundtrip :: proc(t: ^testing.T) {
	events := []input.Event {
		input.Key_Down{key = .Escape, repeat = false},
		input.Key_Up{key = .Enter, modifiers = {.Alt}},
		input.Text{text = 'é'},
		input.Pointer_Down{button = .Right, pos = coords.Logical_Point{3.5, 7}},
		input.Pointer_Up{button = .Left, pos = coords.Logical_Point{1, 2}},
		input.Pointer_Move{pos = coords.Logical_Point{9, 8}, buttons = {.Middle}},
		input.Scroll{pos = coords.Logical_Point{0, 0}, dy = -2},
	}
	for e in events {
		matched := false
		switch v in e {
		case input.Key_Down:
			matched = true
			testing.expect(t, v.key == .Escape && !v.repeat)
		case input.Key_Up:
			matched = true
			testing.expect(t, v.key == .Enter && v.modifiers == {.Alt})
		case input.Text:
			matched = true
			testing.expect(t, v.text == 'é')
		case input.Pointer_Down:
			matched = true
			testing.expect(t, v.button == .Right && v.pos == coords.Logical_Point{3.5, 7})
		case input.Pointer_Up:
			matched = true
			testing.expect(t, v.button == .Left && v.pos == coords.Logical_Point{1, 2})
		case input.Pointer_Move:
			matched = true
			testing.expect(t, v.pos == coords.Logical_Point{9, 8} && v.buttons == {.Middle})
		case input.Scroll:
			matched = true
			testing.expect(t, v.pos == coords.Logical_Point{0, 0} && v.dy == -2 && v.dx == 0)
		}
		testing.expectf(t, matched, "no case matched for %v", e)
	}
}

// test_modifier_set_pins the Modifiers bit-set semantics the adapter
// and consumers rely on (membership, union, intersection).
@(test)
test_modifier_set :: proc(t: ^testing.T) {
	mods: input.Modifiers
	testing.expect(t, mods == {})

	mods += {.Shift, .Ctrl}
	testing.expect(t, .Shift in mods)
	testing.expect(t, .Ctrl in mods)
	testing.expect(t, .Alt not_in mods)
	testing.expect(t, .Super not_in mods)

	mods |= {.Alt}
	testing.expect(t, mods == {.Shift, .Ctrl, .Alt})

	mods -= {.Ctrl}
	testing.expect(t, .Ctrl not_in mods)
	testing.expect(t, mods == {.Shift, .Alt})
}
