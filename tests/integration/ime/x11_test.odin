#+build linux

package ime_test

import "core:testing"
import "core:time"

import xlib "vendor:x11/xlib"

import errs "hammer:core/errs"
import platform "hammer:platform"
import x11ime "hammer:platform/x11ime"

foreign import xtst "system:Xtst"
@(default_calling_convention = "c", link_prefix = "XTest")
foreign xtst {
	FakeKeyEvent :: proc(display: ^xlib.Display, keycode: u32, is_press: b32, delay: uint) -> i32 ---
}

foreign import xext "system:Xext"
@(default_calling_convention = "c")
foreign xext {
	@(link_name = "XTestFlush") XTestFlush :: proc(display: ^xlib.Display) -> i32 ---
}

Capture :: struct {
	preedit:       [128]u8,
	preedit_len:   int,
	caret:         int,
	preedit_count: int,
	done_count:    int,
	commits:       [128]u8,
	commit_len:    int,
	error_count:   int,
}

capture_event :: proc(user: rawptr, event: platform.IME_Event) {
	capture := (^Capture)(user)
	switch event.kind {
	case .Preedit:
		capture.preedit_len = min(len(event.text), len(capture.preedit))
		copy(capture.preedit[:], event.text[:capture.preedit_len])
		capture.caret = event.caret
		capture.preedit_count += 1
	case .Preedit_Caret:
		capture.caret = event.caret
	case .Preedit_Done:
		capture.preedit_len = 0
		capture.caret = 0
		capture.done_count += 1
	case .Commit:
		count := min(len(event.text), len(capture.commits) - capture.commit_len)
		copy(capture.commits[capture.commit_len:], event.text[:count])
		capture.commit_len += count
	case .Error:
		capture.error_count += 1
	}
}

@(test)
test_x11_preedit_callbacks_and_dead_key_commits :: proc(t: ^testing.T) {
	display := xlib.OpenDisplay(nil)
	if !testing.expect(t, display != nil) {
		return
	}
	defer xlib.CloseDisplay(display)
	window := xlib.CreateSimpleWindow(display, xlib.DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0)
	testing.expect(t, window != 0)
	defer xlib.DestroyWindow(display, window)
	xlib.SelectInput(display, window, {.KeyPress, .KeyRelease})
	xlib.MapWindow(display, window)
	xlib.SetInputFocus(display, window, .RevertToPointerRoot, xlib.CurrentTime)
	xlib.Sync(display, false)

	dead_key := xlib.KeysymToKeycode(display, xlib.KeySym.XK_dead_acute)
	remapped := false
	saved := [2]xlib.KeySym{}
	if dead_key == 0 {
		dead_key = xlib.KeysymToKeycode(display, xlib.KeySym.XK_grave)
		if !testing.expect(t, dead_key != 0) {
			return
		}
		keysyms_per: i32
		original := xlib.GetKeyboardMapping(display, dead_key, 1, &keysyms_per)
		if !testing.expect(t, original != nil && keysyms_per >= 2) {
			return
		}
		original_keys := ([^]xlib.KeySym)(original)
		saved = {original_keys[0], original_keys[1]}
		xlib.Free(original)
		replacement := [2]xlib.KeySym{xlib.KeySym.XK_dead_acute, xlib.KeySym.XK_dead_acute}
		xlib.ChangeKeyboardMapping(display, dead_key, 2, &replacement[0], 1)
		xlib.Sync(display, false)
		remapped = true
		for xlib.Pending(display) > 0 {
			event: xlib.XEvent
			xlib.NextEvent(display, &event)
			if event.type == .MappingNotify {
				xlib.RefreshKeyboardMapping(&event.xmapping)
			}
		}
	}
	defer if remapped {
		xlib.ChangeKeyboardMapping(display, dead_key, 2, &saved[0], 1)
		xlib.Sync(display, false)
	}

	capture: Capture
	state: x11ime.State
	init_err := x11ime.init(&state, display, window, {
		service = {notify = capture_event},
		user = &capture,
	})
	defer errs.destroy(&init_err)
	if !testing.expectf(t, errs.ok(init_err), "%v", errs.describe(init_err)) {
		return
	}
	defer x11ime.destroy(&state)

	x11ime.preedit_start(nil, &state, nil)
	preedit := transmute([]byte)string("中a")
	native_text := xlib.XIMText{length = u16(len(preedit))}
	native_text.string.multi_byte = &preedit[0]
	draw := xlib.XIMPreeditDrawCallbackStruct{caret = 2, text = &native_text}
	x11ime.preedit_draw(nil, &state, &draw)
	testing.expect(t, string(capture.preedit[:capture.preedit_len]) == "中a" && capture.caret == 2)
	caret := xlib.XIMPreeditCaretCallbackStruct{position = 1}
	x11ime.preedit_caret(nil, &state, &caret)
	testing.expect(t, capture.caret == 1)
	x11ime.preedit_done(nil, &state, nil)
	testing.expect(t, capture.preedit_len == 0 && capture.done_count == 1)

	e_key := xlib.KeysymToKeycode(display, xlib.KeySym.XK_e)
	a_key := xlib.KeysymToKeycode(display, xlib.KeySym.XK_a)
	if !testing.expect(t, e_key != 0 && a_key != 0) {
		return
	}
	FakeKeyEvent(display, u32(dead_key), true, 0)
	FakeKeyEvent(display, u32(dead_key), false, 0)
	FakeKeyEvent(display, u32(e_key), true, 0)
	FakeKeyEvent(display, u32(e_key), false, 0)
	FakeKeyEvent(display, u32(a_key), true, 0)
	FakeKeyEvent(display, u32(a_key), false, 0)
	XTestFlush(display)

	deadline := time.time_add(time.now(), 8 * time.Second)
	for string(capture.commits[:capture.commit_len]) != "éa" {
		if xlib.Pending(display) == 0 {
			if !testing.expect(t, i64(time.since(deadline)) < 0, "timed out waiting for XIM commits") {
				return
			}
			time.sleep(2 * time.Millisecond)
			continue
		}
		event: xlib.XEvent
		xlib.NextEvent(display, &event)
		x11ime.filter_event(&state, &event)
	}
	testing.expect(t, capture.error_count == 0)
}
