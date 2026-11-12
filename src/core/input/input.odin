// Package input: normalized, backend-free input events (M01.04).
//
// The window backend delivers raw platform events (sokol_app
// CHAR/KEY/MOUSE families). The application layer (`src/main.odin`)
// translates them into these editor-owned events; the rest of the core
// consumes only this package, never the backend types — the M01
// acceptance rule "no dependency-specific code leaks into the core".
//
// Contracts:
//
// - Coordinates are logical layout units (SPECS.md §9.6). The adapter
//   converts framebuffer pixels with `core/coords` before constructing
//   pointer events; DPI is applied exactly once, at that boundary.
// - Events carry raw facts — keys, text, buttons, positions,
//   modifiers — never semantic actions (SPECS.md §10.1). The Acme
//   chord recognition (§10.2) and the shortcut/action dispatch
//   (§10.3/§10.4) are later milestones (M07/M06).
// - `Event` is a tagged union: a value carries exactly one event kind
//   and its kind-specific fields (AGENTS.md §9.3).
package input

import "core:fmt"
import "core:strings"

import coords "../coords"
import errs "../errs"

// Key is the editor's stable key naming, independent of any backend
// keycode set. The backend adapter maps its own keycodes onto these;
// unmapped backend keys arrive as `.Invalid`.
Key :: enum u16 {
	Invalid,
	Space,
	Apostrophe,
	Comma,
	Minus,
	Period,
	Slash,
	D0,
	D1,
	D2,
	D3,
	D4,
	D5,
	D6,
	D7,
	D8,
	D9,
	Semicolon,
	Equal,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Left_Bracket,
	Backslash,
	Right_Bracket,
	Grave_Accent,
	Escape,
	Enter,
	Tab,
	Backspace,
	Insert,
	Delete,
	Right,
	Left,
	Down,
	Up,
	Page_Up,
	Page_Down,
	Home,
	End,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	F25,
	KP_0,
	KP_1,
	KP_2,
	KP_3,
	KP_4,
	KP_5,
	KP_6,
	KP_7,
	KP_8,
	KP_9,
	KP_Decimal,
	KP_Divide,
	KP_Multiply,
	KP_Subtract,
	KP_Add,
	KP_Enter,
	KP_Equal,
	Left_Shift,
	Left_Control,
	Left_Alt,
	Left_Super,
	Right_Shift,
	Right_Control,
	Right_Alt,
	Right_Super,
	Menu,
}

// key_names renders each key for diagnostics. It is indexed by `Key`;
// the test suite verifies every member has a non-empty name.
key_names := [Key]string {
	.Invalid          = "?",
	.Space            = "SPACE",
	.Apostrophe       = "'",
	.Comma            = ",",
	.Minus            = "-",
	.Period           = ".",
	.Slash            = "/",
	.D0               = "0",
	.D1               = "1",
	.D2               = "2",
	.D3               = "3",
	.D4               = "4",
	.D5               = "5",
	.D6               = "6",
	.D7               = "7",
	.D8               = "8",
	.D9               = "9",
	.Semicolon        = ";",
	.Equal            = "=",
	.A                = "A",
	.B                = "B",
	.C                = "C",
	.D                = "D",
	.E                = "E",
	.F                = "F",
	.G                = "G",
	.H                = "H",
	.I                = "I",
	.J                = "J",
	.K                = "K",
	.L                = "L",
	.M                = "M",
	.N                = "N",
	.O                = "O",
	.P                = "P",
	.Q                = "Q",
	.R                = "R",
	.S                = "S",
	.T                = "T",
	.U                = "U",
	.V                = "V",
	.W                = "W",
	.X                = "X",
	.Y                = "Y",
	.Z                = "Z",
	.Left_Bracket     = "[",
	.Backslash        = "\\",
	.Right_Bracket    = "]",
	.Grave_Accent     = "`",
	.Escape           = "ESCAPE",
	.Enter            = "ENTER",
	.Tab              = "TAB",
	.Backspace        = "BACKSPACE",
	.Insert           = "INSERT",
	.Delete           = "DELETE",
	.Right            = "RIGHT",
	.Left             = "LEFT",
	.Down             = "DOWN",
	.Up               = "UP",
	.Page_Up          = "PAGE_UP",
	.Page_Down        = "PAGE_DOWN",
	.Home             = "HOME",
	.End              = "END",
	.Caps_Lock        = "CAPS_LOCK",
	.Scroll_Lock      = "SCROLL_LOCK",
	.Num_Lock         = "NUM_LOCK",
	.Print_Screen     = "PRINT_SCREEN",
	.Pause            = "PAUSE",
	.F1               = "F1",
	.F2               = "F2",
	.F3               = "F3",
	.F4               = "F4",
	.F5               = "F5",
	.F6               = "F6",
	.F7               = "F7",
	.F8               = "F8",
	.F9               = "F9",
	.F10              = "F10",
	.F11              = "F11",
	.F12              = "F12",
	.F13              = "F13",
	.F14              = "F14",
	.F15              = "F15",
	.F16              = "F16",
	.F17              = "F17",
	.F18              = "F18",
	.F19              = "F19",
	.F20              = "F20",
	.F21              = "F21",
	.F22              = "F22",
	.F23              = "F23",
	.F24              = "F24",
	.F25              = "F25",
	.KP_0             = "KP0",
	.KP_1             = "KP1",
	.KP_2             = "KP2",
	.KP_3             = "KP3",
	.KP_4             = "KP4",
	.KP_5             = "KP5",
	.KP_6             = "KP6",
	.KP_7             = "KP7",
	.KP_8             = "KP8",
	.KP_9             = "KP9",
	.KP_Decimal       = "KP_DECIMAL",
	.KP_Divide        = "KP_DIVIDE",
	.KP_Multiply      = "KP_MULTIPLY",
	.KP_Subtract      = "KP_SUBTRACT",
	.KP_Add           = "KP_ADD",
	.KP_Enter         = "KP_ENTER",
	.KP_Equal         = "KP_EQUAL",
	.Left_Shift       = "LEFT_SHIFT",
	.Left_Control     = "LEFT_CONTROL",
	.Left_Alt         = "LEFT_ALT",
	.Left_Super       = "LEFT_SUPER",
	.Right_Shift      = "RIGHT_SHIFT",
	.Right_Control    = "RIGHT_CONTROL",
	.Right_Alt        = "RIGHT_ALT",
	.Right_Super      = "RIGHT_SUPER",
	.Menu             = "MENU",
}

// key_name renders `k` for diagnostics ("A", "ESCAPE", "?").
key_name :: proc(k: Key) -> string {
	return key_names[k]
}

// Modifier is a held modifier key; Modifiers is the set of them.
Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super,
}
Modifiers :: bit_set[Modifier; u8]

// Mouse_Button identifies a mouse button in down/up events. There is
// deliberately no Invalid member: the adapter drops backend events
// with unrecognized buttons instead of smuggling them into the core.
Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

// Mouse_Buttons is the set of currently held mouse buttons, as
// reported by the backend in move events.
Mouse_Buttons :: bit_set[Mouse_Button; u8]

// Key_Down is a key press. `repeat` marks a backend auto-repeat; a
// chord or shortcut consumer should ignore repeats.
Key_Down :: struct {
	key:       Key,
	repeat:    bool,
	modifiers: Modifiers,
}

// Key_Up is a key release.
Key_Up :: struct {
	key:       Key,
	modifiers: Modifiers,
}

// Text is a committed character (backend CHAR events; M06.07 routes
// IME commits here too). `text` is a valid Unicode scalar value —
// validated by `normalize_text` at the adapter boundary.
Text :: struct {
	text:      rune,
	modifiers: Modifiers,
}

// Pointer_Down is a mouse button press at a logical position.
Pointer_Down :: struct {
	button:    Mouse_Button,
	pos:       coords.Logical_Point,
	modifiers: Modifiers,
}

// Pointer_Up is a mouse button release at a logical position.
Pointer_Up :: struct {
	button:    Mouse_Button,
	pos:       coords.Logical_Point,
	modifiers: Modifiers,
}

// Pointer_Move is a pointer motion in logical coordinates. `buttons`
// carries the held buttons as reported by the backend (the §10.2
// state machine still owns the authoritative pressed state).
Pointer_Move :: struct {
	pos:       coords.Logical_Point,
	buttons:   Mouse_Buttons,
	modifiers: Modifiers,
}

// Scroll is a wheel/touchpad scroll at a logical position. `dx`/`dy`
// are backend wheel notches (positive = down/right on the X11
// backend); they are not pixel distances and are not DPI-scaled.
Scroll :: struct {
	pos:       coords.Logical_Point,
	dx:        f32,
	dy:        f32,
	modifiers: Modifiers,
}

// Event is one normalized input event: a tagged union whose tag
// selects exactly one kind-specific payload.
Event :: union {
	Key_Down,
	Key_Up,
	Text,
	Pointer_Down,
	Pointer_Up,
	Pointer_Move,
	Scroll,
}

// normalize_text validates a backend character code (UTF-32) and
// returns it as a rune. Rejects NUL, UTF-16 surrogate halves, and
// values beyond U+10FFFF — backend input is external data and is
// never asserted on (AGENTS.md §11.2).
normalize_text :: proc(code: u32) -> (rune, errs.Error) {
	if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
		return 0, errs.newf(.Invalid_Input, "input: invalid character code U+%X", code)
	}
	return rune(code), {}
}

// button_name renders a mouse button for diagnostics.
button_name :: proc(b: Mouse_Button) -> string {
	switch b {
	case .Left:
		return "LEFT"
	case .Middle:
		return "MIDDLE"
	case .Right:
		return "RIGHT"
	}
	return "?"
}

// modifier_name renders a modifier for diagnostics.
modifier_name :: proc(m: Modifier) -> string {
	switch m {
	case .Shift:
		return "SHIFT"
	case .Ctrl:
		return "CTRL"
	case .Alt:
		return "ALT"
	case .Super:
		return "SUPER"
	}
	return "?"
}

// modifiers_string renders a modifier set as "SHIFT+CTRL", or ""
// when empty. Scratch-allocated: valid until the next temp-arena
// reset (the same contract as `errs.describe`).
modifiers_string :: proc(mods: Modifiers, allocator := context.temp_allocator) -> string {
	if mods == {} {
		return ""
	}
	b := strings.builder_make(0, 32, allocator)
	first := true
	for m in Modifier {
		if m in mods {
			if !first {
				strings.write_byte(&b, '+')
			}
			first = false
			strings.write_string(&b, modifier_name(m))
		}
	}
	return strings.to_string(b)
}

// buttons_string renders a held-button set as "LEFT+RIGHT", or ""
// when empty. Scratch-allocated (same contract as `modifiers_string`).
buttons_string :: proc(buttons: Mouse_Buttons, allocator := context.temp_allocator) -> string {
	if buttons == {} {
		return ""
	}
	b := strings.builder_make(0, 32, allocator)
	first := true
	for m in Mouse_Button {
		if m in buttons {
			if !first {
				strings.write_byte(&b, '+')
			}
			first = false
			strings.write_string(&b, button_name(m))
		}
	}
	return strings.to_string(b)
}

// mods_suffix renders " mods=SHIFT+CTRL" for a non-empty set, else
// "". Scratch-allocated (same contract as `modifiers_string`).
mods_suffix :: proc(mods: Modifiers, allocator := context.temp_allocator) -> string {
	if mods == {} {
		return ""
	}
	return fmt.aprintf(" mods=%s", modifiers_string(mods, allocator), allocator = allocator)
}

// describe renders a one-line debug representation of `e`, e.g.
// `key down ESCAPE`, `text 'a' (U+0061)`, `pointer down LEFT at
// 150,100`, `scroll dx=0 dy=-1 at 150,100 mods=CTRL`.
// Scratch-allocated: valid until the next temp-arena reset.
describe :: proc(e: Event, allocator := context.temp_allocator) -> string {
	switch v in e {
	case Key_Down:
		if v.repeat {
			return fmt.aprintf(
				"key down %s (repeat)%s",
				key_name(v.key),
				mods_suffix(v.modifiers, allocator),
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"key down %s%s",
			key_name(v.key),
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Key_Up:
		return fmt.aprintf(
			"key up %s%s",
			key_name(v.key),
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Text:
		if v.text >= 0x20 && v.text != 0x7F {
			return fmt.aprintf(
				"text '%c' (U+%04X)%s",
				v.text,
				u32(v.text),
				mods_suffix(v.modifiers, allocator),
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"text U+%04X%s",
			u32(v.text),
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Pointer_Down:
		return fmt.aprintf(
			"pointer down %s at %v,%v%s",
			button_name(v.button),
			v.pos.x,
			v.pos.y,
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Pointer_Up:
		return fmt.aprintf(
			"pointer up %s at %v,%v%s",
			button_name(v.button),
			v.pos.x,
			v.pos.y,
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Pointer_Move:
		held := buttons_string(v.buttons, allocator)
		if held == "" {
			return fmt.aprintf(
				"move at %v,%v%s",
				v.pos.x,
				v.pos.y,
				mods_suffix(v.modifiers, allocator),
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"move at %v,%v buttons=%s%s",
			v.pos.x,
			v.pos.y,
			held,
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	case Scroll:
		return fmt.aprintf(
			"scroll dx=%v dy=%v at %v,%v%s",
			v.dx,
			v.dy,
			v.pos.x,
			v.pos.y,
			mods_suffix(v.modifiers, allocator),
			allocator = allocator,
		)
	}
	return "?"
}
