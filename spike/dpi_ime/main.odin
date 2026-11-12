// M00.05 — Mixed-DPI and text-input/IME spike (Linux/X11 only).
//
// A standalone X11 probe program with several modes. Together with the
// sapp probe app in ./app and the demo harness (demo.sh), it establishes
// what the pinned sokol_app revision actually does on X11 regarding DPI
// and text input, and proves that a native XIM (X Input Method) bridge
// can provide IME preedit/commit handling that sapp does not expose.
//
// Modes:
//
//   dpi_ime probe
//       Prints the DPI inputs that exist on X11: the Xft.dpi resource,
//       the mm-based screen DPI, per-monitor RandR data, and XTEST
//       availability.
//
//   dpi_ime set-dpi <value>   /   dpi_ime clear-dpi
//       Writes/removes an "Xft.dpi" entry in the root window's
//       RESOURCE_MANAGER property (the same mechanism xrdb uses) and then
//       holds the connection open until killed. The hold matters: X
//       servers reset their state when the last client disconnects, so a
//       short-lived writer would lose its own write.
//
//   dpi_ime xim
//       The XIM bridge prototype: opens an input method, creates an input
//       context with preedit callbacks on a hidden window, feeds itself a
//       dead-key sequence plus plain keys via XTEST, and reports the
//       preedit/commit traffic. Exits nonzero if composition fails.
//
//   dpi_ime keys --window <id> [--motion x,y]
//       Feeds fake key/mouse events (XTEST) to another window; used to
//       drive the sapp probe app from the demo harness.
//
// Findings are recorded in docs/m00-05-dpi-ime.md. This is spike code,
// not the product implementation.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import libc "core:c/libc"

import xlib "vendor:x11/xlib"

import "spike:dpi_ime/xutil"

// ---- XTEST bindings (hand-written; vendor:x11 has no Xtst bindings) ----

foreign import xtst "system:Xtst"
@(default_calling_convention = "c", link_prefix = "XTest")
foreign xtst {
	QueryExtension :: proc(
		dpy: ^xlib.Display,
		event_base, error_base, major, minor: ^i32,
	) -> b32 ---
	FakeKeyEvent :: proc(
		dpy: ^xlib.Display,
		keycode: u32,
		is_press: b32,
		delay: uint,
	) -> i32 ---
	FakeButtonEvent :: proc(
		dpy: ^xlib.Display,
		button: u32,
		is_press: b32,
		delay: uint,
	) -> i32 ---
	FakeMotionEvent :: proc(
		dpy: ^xlib.Display,
		screen: i32,
		x, y: i32,
		delay: uint,
	) -> i32 ---
}

// XTestFlush lives in libXext (unlike the rest of the XTest API, which
// lives in libXtst).
foreign import xext "system:Xext"
@(default_calling_convention = "c")
foreign xext {
	@(link_name = "XTestFlush")
	XTestFlush :: proc(dpy: ^xlib.Display) -> i32 ---
}

// ---- RandR helper (XRRFreeMonitors is missing from vendor:x11) ------------

foreign import xrandr_free "system:Xrandr"
@(default_calling_convention = "c", link_prefix = "XRR")
foreign xrandr_free {
	FreeMonitors :: proc(monitors: [^]xlib.XRRMonitorInfo, nmonitors: i32) ---
}

// ---- XIM bindings missing from vendor:x11 ---------------------------------
//
// vendor:x11/xlib already binds OpenIM/SetLocaleModifiers/CreateIC/
// SetICFocus/FilterEvent/XIMCallback/XIMText/etc. The four calls below
// are missing there. XGetIMValues and XmbLookupString are C variadic/
// fixed calls that do not take structs by value, so fixed-arity
// declarations linked to the real symbols generate correct calls.

foreign import ximlib "system:X11"
@(default_calling_convention = "c")
foreign ximlib {
	@(link_name = "XCloseIM") CloseIM :: proc(im: xlib.XIM) -> i32 ---
	@(link_name = "XDestroyIC") DestroyIC :: proc(ic: xlib.XIC) ---
	// XGetIMValues(im, XNQueryInputStyle, &styles, NULL)
	@(link_name = "XGetIMValues") GetIMValues_Styles :: proc(
		im: xlib.XIM,
		name: cstring,
		out: rawptr,
		term: cstring,
	) -> cstring ---
	@(link_name = "XmbLookupString") mbLookupString :: proc(
		ic: xlib.XIC,
		event: ^xlib.XKeyEvent,
		buffer: [^]u8,
		bytes: i32,
		keysym: ^xlib.KeySym,
		status: ^i32,
	) -> i32 ---
}

// Preedit-callbacks container (Xutil.h XIMPreeditCallbacks; not in
// vendor:x11). Passed to XCreateIC by pointer via the XNPreeditAttributes
// argument.
Preedit_Callbacks :: struct {
	client_data:    rawptr,
	start_callback: xlib.XIMCallback,
	draw_callback:  xlib.XIMCallback,
	caret_callback: xlib.XIMCallback,
	done_callback:  xlib.XIMCallback,
}

// Input-style bits (Xlib.h; the XN* macros' values on this machine).
XIMPreeditArea :: xlib.XIMStyle(0x0001)
XIMPreeditCallbacks :: xlib.XIMStyle(0x0002)
XIMPreeditPosition :: xlib.XIMStyle(0x0004)
XIMPreeditNothing :: xlib.XIMStyle(0x0008)
XIMPreeditNone :: xlib.XIMStyle(0x0010)
XIMStatusArea :: xlib.XIMStyle(0x0100)
XIMStatusCallbacks :: xlib.XIMStyle(0x0200)
XIMStatusNothing :: xlib.XIMStyle(0x0400)
XIMStatusNone :: xlib.XIMStyle(0x0800)

style_name :: proc(style: xlib.XIMStyle) -> string {
	parts: [dynamic]string
	defer delete(parts)
	switch style & 0x001f {
	case 0x0001: append(&parts, "PreeditArea")
	case 0x0002: append(&parts, "PreeditCallbacks")
	case 0x0004: append(&parts, "PreeditPosition")
	case 0x0008: append(&parts, "PreeditNothing")
	case 0x0010: append(&parts, "PreeditNone")
	case: append(&parts, fmt.tprintf("Preedit?0x%x", style & 0x001f))
	}
	switch style & 0x0f00 {
	case 0x0100: append(&parts, "StatusArea")
	case 0x0200: append(&parts, "StatusCallbacks")
	case 0x0400: append(&parts, "StatusNothing")
	case 0x0800: append(&parts, "StatusNone")
	case: append(&parts, fmt.tprintf("Status?0x%x", style & 0x0f00))
	}
	return strings.join(parts[:], "+", context.temp_allocator)
}

// ---- shared display helpers ------------------------------------------------

open_display :: proc() -> (^xlib.Display, bool) {
	dpy := xlib.OpenDisplay(nil)
	if dpy == nil {
		fmt.eprintln("error: XOpenDisplay failed (is DISPLAY set?)")
		return nil, false
	}
	return dpy, true
}

make_hidden_window :: proc(dpy: ^xlib.Display, mask: xlib.EventMask) -> xlib.Window {
	window := xlib.CreateSimpleWindow(
		dpy,
		xlib.DefaultRootWindow(dpy),
		0, 0, 1, 1, 0, 0, 0,
	)
	xlib.SelectInput(dpy, window, mask)
	xlib.MapWindow(dpy, window)
	return window
}

// ---- probe ------------------------------------------------------------------

probe_mode :: proc() -> int {
	dpy, ok := open_display()
	if !ok {
		return 1
	}
	defer xlib.CloseDisplay(dpy)

	// XTEST availability (used by the xim/keys modes to feed fake input).
	ev_base, err_base, major, minor: i32
	if QueryExtension(dpy, &ev_base, &err_base, &major, &minor) {
		fmt.printf("XTEST: yes (version %d.%d)\n", major, minor)
	} else {
		fmt.println("XTEST: no")
	}

	// Xft.dpi resource (what sapp's X11 backend consumes).
	res, found := xutil.resource_manager_string(dpy)
	if found {
		defer delete(res)
		if value, has_xft := xutil.xft_dpi_value(res); has_xft {
			fmt.printf("Xft.dpi: %.3f\n", value)
		} else {
			fmt.println("Xft.dpi: unset")
		}
	} else {
		fmt.println("Xft.dpi: unset")
	}

	// mm-based DPI (what sapp ignores on X11).
	screen_count := xlib.ScreenCount(dpy)
	for screen in 0 ..< screen_count {
		w := xlib.DisplayWidth(dpy, screen)
		h := xlib.DisplayHeight(dpy, screen)
		if dpi, has_dpi := xutil.screen_dpi(dpy, screen); has_dpi {
			fmt.printf("screen %d: %dx%d px, %.0f dpi (mm-based)\n", screen, w, h, dpi)
		} else {
			fmt.printf("screen %d: %dx%d px, mm unknown (mm-based dpi unavailable)\n", screen, w, h)
		}
	}

	// Per-monitor RandR data (the native source for mixed-DPI handling).
	nmonitors: i32
	monitors := xlib.XRRGetMonitors(dpy, xlib.DefaultRootWindow(dpy), true, &nmonitors)
	defer if monitors != nil {
		FreeMonitors(monitors, nmonitors)
	}
	fmt.printf("monitors: %d\n", nmonitors)
	for i in 0 ..< nmonitors {
		m := monitors[i]
		monitor_name := "?"
		if cs := xlib.GetAtomName(dpy, m.name); cs != nil {
			monitor_name = string(cs)
		}
		mm := "unknown (0 mm)"
		if m.mwidth > 0 && m.mheight > 0 {
			mm = fmt.tprintf(
				"%.1f dpi",
				f64(m.width) * 25.4 / f64(m.mwidth),
			)
		}
		fmt.printf(
			"  monitor[%d]: %q %dx%d+%d+%d mm=%dx%d (%s)\n",
			i, monitor_name, m.width, m.height, m.x, m.y, m.mwidth, m.mheight, mm,
		)
	}
	return 0
}

// ---- Xft.dpi resource management -------------------------------------------

// set_xft_dpi_entry replaces (or appends) the "Xft.dpi:" line in the root
// RESOURCE_MANAGER string; with remove=true it drops the line instead.
set_xft_dpi_entry :: proc(dpy: ^xlib.Display, value: f64, remove: bool) -> bool {
	res, found := xutil.resource_manager_string(dpy)
	defer if found {
		delete(res)
	}

	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)

	written := false
	if found {
		lines := strings.split(res, "\n", context.temp_allocator)
		for line in lines {
			trimmed := strings.trim_left_space(line)
			if len(trimmed) >= 7 && strings.equal_fold(trimmed[:7], "xft.dpi") {
				if remove {
					written = true // drop the line
				} else {
					fmt.sbprintf(&builder, "Xft.dpi:\t%.3f\n", value)
					written = true
				}
				continue
			}
			fmt.sbprintln(&builder, line)
		}
	}
	if !written && !remove {
		fmt.sbprintf(&builder, "Xft.dpi:\t%.3f\n", value)
	}

	atom := xlib.InternAtom(dpy, cstring("RESOURCE_MANAGER"), false)
	string_atom := xlib.InternAtom(dpy, cstring("STRING"), false)
	new_res := strings.to_string(builder)
	if len(new_res) == 0 {
		xlib.DeleteProperty(dpy, xlib.DefaultRootWindow(dpy), atom)
	} else {
		bytes := transmute([]u8)new_res
		xlib.ChangeProperty(
			dpy,
			xlib.DefaultRootWindow(dpy),
			atom,
			string_atom,
			8,
			xlib.PropModeReplace,
			rawptr(&bytes[0]),
			i32(len(bytes)),
		)
	}
	xlib.Sync(dpy, false)
	return true
}

// ---- XIM bridge prototype ----------------------------------------------------

preedit_start :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^xlib.XIMPreeditState)(call_data)
	fmt.printf("preedit-start: state=%x\n", state^)
}

preedit_draw :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	cb := (^xlib.XIMPreeditDrawCallbackStruct)(call_data)
	fmt.printf("preedit-draw: caret=%d chg_first=%d chg_length=%d", cb.caret, cb.chg_first, cb.chg_length)
	if cb.text != nil && cb.text.length > 0 {
		if cb.text.encoding_is_wchar {
			fmt.printf(" text=<wide-char preedit, not decoded by this spike>")
		} else {
			fmt.printf(" text=%q", string(cb.text.string.multi_byte[:cb.text.length]))
		}
		if cb.text.feedback != nil {
			feedback := ([^]xlib.XIMFeedback)(cb.text.feedback)
			fmt.printf(" feedback=[")
			for i in 0 ..< int(cb.text.length) {
				fmt.printf(" %d", feedback[i])
			}
			fmt.printf(" ]")
		}
	}
	fmt.println()
}

preedit_caret :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	cb := (^xlib.XIMPreeditDrawCallbackStruct)(call_data)
	fmt.printf("preedit-caret: caret=%d chg_first=%d chg_length=%d\n", cb.caret, cb.chg_first, cb.chg_length)
}

preedit_done :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^xlib.XIMPreeditState)(call_data)
	fmt.printf("preedit-done: state=%x\n", state^)
}

lookup_status_name :: proc(status: i32) -> string {
	switch xlib.LookupStringStatus(status) {
	case .BufferOverflow:
		return "BufferOverflow"
	case .LookupNone:
		return "LookupNone"
	case .LookupChars:
		return "LookupChars"
	case .LookupKeySym:
		return "LookupKeySym"
	case .LookupBoth:
		return "LookupBoth"
	}
	return "?"
}

xim_mode :: proc() -> int {
	// Locale: XIM requires a locale that supports input methods; apply
	// the process environment's locale (the demo harness pins a UTF-8
	// locale).
	current := libc.setlocale(libc.Locale_Category.CTYPE, cstring(""))
	if current == nil {
		fmt.eprintln("error: setlocale failed; XIM needs a locale-aware LC_CTYPE")
		return 1
	}
	fmt.printf("locale: %s\n", string(current))
	xlib.SetLocaleModifiers(cstring(""))

	dpy, ok := open_display()
	if !ok {
		return 1
	}
	defer xlib.CloseDisplay(dpy)

	window := make_hidden_window(dpy, {.KeyPress, .KeyRelease})
	defer xlib.DestroyWindow(dpy, window)
	xlib.SetInputFocus(dpy, window, .RevertToPointerRoot, xlib.CurrentTime)
	xlib.Sync(dpy, false)

	// The built-in XIM caches the keymap when the input context is
	// created, so a dead-key remap must happen BEFORE XOpenIM. The
	// default keymap has no dead keys, so temporarily remap the grave key
	// and restore it on exit. NOTE: the restore defer must live at PROC
	// scope — Odin defers are block-scoped, and a defer inside the `if`
	// block would restore the keymap immediately at block exit, before
	// the XIM ever reads it.
	dead_kc := xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_dead_acute)
	remap_done := false
	saved_keysyms := [2]xlib.KeySym{}
	if dead_kc == 0 {
		dead_kc = xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_grave)
		if dead_kc == 0 {
			fmt.eprintln("error: no keycode for dead_acute or grave; cannot build a dead-key script")
			return 1
		}
		keysyms_per: i32
		original_ptr := xlib.GetKeyboardMapping(dpy, dead_kc, 1, &keysyms_per)
		if original_ptr == nil || keysyms_per < 2 {
			fmt.eprintln("error: XGetKeyboardMapping failed")
			return 1
		}
		original := ([^]xlib.KeySym)(original_ptr)
		saved_keysyms = [2]xlib.KeySym{original[0], original[1]}
		xlib.Free(original_ptr)
		remap := [2]xlib.KeySym{xlib.KeySym.XK_dead_acute, xlib.KeySym.XK_dead_acute}
		xlib.ChangeKeyboardMapping(dpy, dead_kc, 2, &remap[0], 1)
		xlib.Sync(dpy, false)
		remap_done = true
		// Drain the MappingNotify events so Xlib's client-side keymap
		// cache is refreshed BEFORE the XIM snapshots it at XCreateIC.
		drained := 0
		for xlib.Pending(dpy) > 0 {
			ev: xlib.XEvent
			xlib.NextEvent(dpy, &ev)
			if ev.type == .MappingNotify {
				xlib.RefreshKeyboardMapping(&ev.xmapping)
			}
			drained += 1
		}
		fmt.printf("note: remapped keycode %d to dead_acute (drained %d event(s))\n", dead_kc, drained)
	}
	defer if remap_done {
		xlib.ChangeKeyboardMapping(dpy, dead_kc, 2, &saved_keysyms[0], 1)
		xlib.Sync(dpy, false)
	}

	im := xlib.OpenIM(dpy, nil, nil, nil)
	if im == nil {
		fmt.eprintln("error: XOpenIM failed (locale or IM server problem); check LC_CTYPE and XMODIFIERS")
		return 1
	}
	defer CloseIM(im)

	styles_ptr: ^xlib.XIMStyles
	if err_msg := GetIMValues_Styles(im, cstring("queryInputStyle"), rawptr(&styles_ptr), nil); err_msg != nil {
		fmt.eprintf("error: XGetIMValues(XNQueryInputStyle) failed: %q\n", string(err_msg))
		return 1
	}
	if styles_ptr == nil || styles_ptr.count_styles == 0 {
		fmt.eprintln("error: input method advertised no styles")
		return 1
	}
	fmt.printf("supported styles: %d\n", styles_ptr.count_styles)
	supports_preedit_callbacks := false
	for i in 0 ..< int(styles_ptr.count_styles) {
		style := styles_ptr.supported_styles[i]
		fmt.printf("  style[%d]: 0x%x (%s)\n", i, style, style_name(style))
		if (style & XIMPreeditCallbacks) != 0 {
			supports_preedit_callbacks = true
		}
	}
	fmt.printf("XIMPreeditCallbacks supported: %t\n", supports_preedit_callbacks)

	// Negotiate a style:
	//   - prefer preedit callbacks (real IME servers such as the ibus XIM
	//     bridge advertise this; the built-in XIM on this headless display
	//     does not),
	//   - fall back to PreeditNothing|StatusNothing (0x408), then to the
	//     first advertised style.
	chosen: xlib.XIMStyle
	chosen_has_callbacks := false
	if supports_preedit_callbacks {
		for i in 0 ..< int(styles_ptr.count_styles) {
			style := styles_ptr.supported_styles[i]
			if (style & XIMPreeditCallbacks) != 0 && (style & XIMStatusNothing) != 0 {
				chosen = style
				chosen_has_callbacks = true
				break
			}
		}
	}
	if chosen == 0 {
		for i in 0 ..< int(styles_ptr.count_styles) {
			style := styles_ptr.supported_styles[i]
			if style == XIMPreeditNothing | XIMStatusNothing {
				chosen = style
				break
			}
		}
	}
	if chosen == 0 {
		chosen = styles_ptr.supported_styles[0]
	}
	fmt.printf("chosen style: 0x%x (%s)\n", chosen, style_name(chosen))
	xlib.Free(styles_ptr)

	callbacks := Preedit_Callbacks{
		client_data = nil,
		start_callback = xlib.XIMCallback{callback = preedit_start},
		draw_callback = xlib.XIMCallback{callback = preedit_draw},
		caret_callback = xlib.XIMCallback{callback = preedit_caret},
		done_callback = xlib.XIMCallback{callback = preedit_done},
	}

	ic: xlib.XIC
	if chosen_has_callbacks {
		ic = xlib.CreateIC(
			im,
			cstring("inputStyle"), chosen,
			cstring("clientWindow"), window,
			cstring("focusWindow"), window,
			cstring("preeditAttributes"), &callbacks,
			nil,
		)
	} else {
		ic = xlib.CreateIC(
			im,
			cstring("inputStyle"), chosen,
			cstring("clientWindow"), window,
			cstring("focusWindow"), window,
			nil,
		)
	}
	if ic == nil {
		fmt.eprintln("error: XCreateIC failed")
		return 1
	}
	defer DestroyIC(ic)
	xlib.SetICFocus(ic)

	// Feed a dead-key sequence + plain keys. XTEST injects real events
	// with server-side delays, so the keymap state (dead keys) is
	// processed correctly.
	e_kc := xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_e)
	a_kc := xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_a)
	if e_kc == 0 || a_kc == 0 {
		fmt.eprintln("error: keymap missing 'e'/'a' keycodes")
		return 1
	}

	delay := uint(200)
	FakeKeyEvent(dpy, u32(dead_kc), true, delay)
	FakeKeyEvent(dpy, u32(dead_kc), false, delay)
	FakeKeyEvent(dpy, u32(e_kc), true, delay)
	FakeKeyEvent(dpy, u32(e_kc), false, delay)
	FakeKeyEvent(dpy, u32(a_kc), true, delay)
	FakeKeyEvent(dpy, u32(a_kc), false, delay)
	XTestFlush(dpy)

	// Process events until the script has been delivered and composed.
	committed: [dynamic]u8
	defer delete(committed)
	saw_e_acute := false
	saw_plain_a := false

	deadline := time.time_add(time.now(), 8 * time.Second)
	for !saw_e_acute || !saw_plain_a {
		if xlib.Pending(dpy) == 0 {
			if i64(time.since(deadline)) >= 0 {
				fmt.eprintln("error: timed out waiting for key events")
				return 1
			}
			time.sleep(2 * time.Millisecond)
			continue
		}
		ev: xlib.XEvent
		xlib.NextEvent(dpy, &ev)
		// Feed KEY events through XFilterEvent so the input method can
		// consume them. MappingNotify must NOT go through the filter:
		// the local filter would parse the mapping event's bytes as a
		// key event and corrupt its compose state; refresh the keymap
		// cache for it instead.
		if ev.type == .MappingNotify {
			xlib.RefreshKeyboardMapping(&ev.xmapping)
			continue
		}
		if ev.type != .KeyPress {
			continue
		}
		if xlib.FilterEvent(&ev, window) {
			fmt.println("key event consumed by the input method (XFilterEvent)")
			continue
		}
		buf: [64]u8
		keysym: xlib.KeySym
		status: i32
		n := mbLookupString(ic, &ev.xkey, &buf[0], 64, &keysym, &status)
		fmt.printf("lookup: status=%s keysym=0x%x bytes=%d\n", lookup_status_name(status), uint(keysym), n)
		if n > 0 && n < len(buf) {
			text := string(buf[:n])
			fmt.printf("commit: %q\n", text)
			append(&committed, ..buf[:n])
			if strings.contains(text, "é") {
				saw_e_acute = true
			}
			if text == "a" {
				saw_plain_a = true
			}
		}
	}

	fmt.printf("committed total: %q\n", string(committed[:]))
	if !saw_e_acute {
		fmt.eprintln("error: dead-key composition did not produce é")
		return 1
	}
	fmt.printf("preedit-callbacks: exercised=%t\n", chosen_has_callbacks)
	fmt.println("RESULT: OK")
	return 0
}

// ---- keys feeder -------------------------------------------------------------

keys_mode :: proc(args: []string) -> int {
	window_str := ""
	motion_x, motion_y: i32
	motion_set := false

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--window":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for --window")
			}
			window_str = args[i]
		case "--motion":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for --motion")
			}
			x, y, ok := parse_point(args[i])
			if !ok {
				return usage_error("invalid --motion value (want x,y)")
			}
			motion_x, motion_y = x, y
			motion_set = true
		case:
			return usage_error(fmt.tprintf("unknown argument %q", args[i]))
		}
		i += 1
	}
	if window_str == "" {
		return usage_error("missing --window")
	}
	id, parsed := parse_window_id(window_str)
	if !parsed {
		return usage_error("invalid --window id (want decimal or 0x hex)")
	}

	dpy, ok := open_display()
	if !ok {
		return 1
	}
	defer xlib.CloseDisplay(dpy)

	xlib.SetInputFocus(dpy, xlib.Window(id), .RevertToPointerRoot, xlib.CurrentTime)
	xlib.Sync(dpy, false)

	total_delay := uint(0)

	shift_kc := u32(xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_Shift_L))
	a_kc := u32(xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_a))
	one_kc := u32(xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_1))
	space_kc := u32(xlib.KeysymToKeycode(dpy, xlib.KeySym.XK_space))
	if shift_kc == 0 || a_kc == 0 || one_kc == 0 || space_kc == 0 {
		fmt.eprintln("error: keymap missing needed keycodes")
		return 1
	}

	d := uint(150)
	// 'a'
	send_key(dpy, a_kc, true, d, &total_delay)
	send_key(dpy, a_kc, false, d, &total_delay)
	// 'A' via shift
	send_key(dpy, shift_kc, true, d, &total_delay)
	send_key(dpy, a_kc, true, d, &total_delay)
	send_key(dpy, a_kc, false, d, &total_delay)
	send_key(dpy, shift_kc, false, d, &total_delay)
	// '1'
	send_key(dpy, one_kc, true, d, &total_delay)
	send_key(dpy, one_kc, false, d, &total_delay)
	// space
	send_key(dpy, space_kc, true, d, &total_delay)
	send_key(dpy, space_kc, false, d, &total_delay)

	if motion_set {
		FakeMotionEvent(dpy, 0, motion_x, motion_y, 100)
		total_delay += 100
	}
	XTestFlush(dpy)

	// Let the server deliver everything, then exit.
	time.sleep(time.Duration(total_delay) * time.Millisecond + 400 * time.Millisecond)
	fmt.printf("sent fake key events (window 0x%x)\n", id)
	return 0
}

parse_point :: proc(s: string) -> (x, y: i32, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 2 {
		return 0, 0, false
	}
	xv, xok := strconv.parse_int(parts[0])
	yv, yok := strconv.parse_int(parts[1])
	return i32(xv), i32(yv), xok && yok
}

send_key :: proc(dpy: ^xlib.Display, keycode: u32, press: b32, delay: uint, total: ^uint) {
	FakeKeyEvent(dpy, keycode, press, delay)
	total^ += delay
}

parse_window_id :: proc(s: string) -> (uint, bool) {
	if len(s) > 2 && (s[:2] == "0x" || s[:2] == "0X") {
		value, ok := strconv.parse_u64(s[2:], 16)
		return uint(value), ok
	}
	value, ok := strconv.parse_u64(s, 10)
	return uint(value), ok
}

usage_error :: proc(msg: string) -> int {
	fmt.eprintf("error: %s\n", msg)
	usage()
	return 2
}

// hold_open keeps the connection alive forever (until the harness kills
// the process). X servers reset their state when the last client
// disconnects, so a process that writes root-window state (like the
// Xft.dpi resource) must stay connected while consumers read it.
hold_open :: proc(dpy: ^xlib.Display) {
	for {
		ev: xlib.XEvent
		xlib.NextEvent(dpy, &ev)
	}
}

// ---- CLI --------------------------------------------------------------------

usage :: proc() {
	fmt.eprintln(`usage:
  dpi_ime probe
  dpi_ime set-dpi <value>
  dpi_ime clear-dpi
  dpi_ime xim
  dpi_ime keys --window <id> [--motion x,y]`)
}

report_leaks :: proc(track: ^mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	defer report_leaks(&track)

	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}

	switch args[0] {
	case "probe":
		os.exit(probe_mode())
	case "set-dpi":
		if len(args) != 2 {
			os.exit(usage_error("set-dpi needs a value"))
		}
		value, ok := strconv.parse_f64(args[1])
		if !ok || value <= 0 {
			os.exit(usage_error("invalid dpi value"))
		}
		dpy, dok := open_display()
		if !dok {
			os.exit(1)
		}
		set_xft_dpi_entry(dpy, value, false)
		fmt.printf("ready Xft.dpi=%.3f\n", value)
		hold_open(dpy) // run until killed; keeps the server state alive
		os.exit(0)
	case "clear-dpi":
		dpy, dok := open_display()
		if !dok {
			os.exit(1)
		}
		set_xft_dpi_entry(dpy, 0, true)
		fmt.println("ready Xft.dpi cleared")
		hold_open(dpy) // run until killed; keeps the server state alive
		os.exit(0)
	case "xim":
		os.exit(xim_mode())
	case "keys":
		os.exit(keys_mode(args[1:]))
	case:
		os.exit(usage_error("unknown mode"))
	}
}
