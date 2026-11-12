// M00.05 — sapp probe app (Linux/X11 only).
//
// A minimal sokol_app window that reports, from inside the app, exactly
// what the pinned sokol_app revision exposes regarding DPI and text
// input on X11:
//
//   - the native window id (so the keys feeder can target it)
//   - the physical window size in pixels (XGetWindowAttributes)
//   - sapp.width()/height() (the framebuffer size)
//   - sapp.dpi_scale() and sapp.high_dpi()
//   - the Xft.dpi resource value (what sapp's X11 backend actually uses)
//   - the mm-based screen DPI (what sapp ignores)
//   - CHAR / KEY_DOWN / MOUSE_* / RESIZED events as they arrive
//
// Driven headlessly by spike/dpi_ime/demo.sh under Xvfb, with fake input
// from the `dpi_ime keys` mode. No rendering is done; sokol_gfx is not
// needed for this spike.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"

import sapp "sokol:app"

import xlib "vendor:x11/xlib"

import "spike:dpi_ime/xutil"

state: State

State :: struct {
	first_frame_done: bool,
	frame_count:      i64,
	autoquit_frames:  i64, // 0 = disabled
}

init :: proc "c" () {
	context = runtime.default_context()
	state.autoquit_frames = autoquit_frames_from_env()
}

frame :: proc "c" () {
	context = runtime.default_context()

	state.frame_count += 1
	if !state.first_frame_done {
		state.first_frame_done = true
		report_metrics()
	}
	if state.autoquit_frames > 0 && state.frame_count >= state.autoquit_frames {
		fmt.printf(">> autoquit after %v frames\n", state.frame_count)
		sapp.request_quit()
	}
}

event :: proc "c" (ev: ^sapp.Event) {
	context = runtime.default_context()

	#partial switch ev.type {
	case .CHAR:
		fmt.printf(">> char U+%04X repeat=%t\n", ev.char_code, ev.key_repeat)
	case .KEY_DOWN:
		fmt.printf(">> keydown code=%d repeat=%t\n", ev.key_code, ev.key_repeat)
	case .KEY_UP:
		fmt.printf(">> keyup code=%d\n", ev.key_code)
	case .MOUSE_MOVE:
		fmt.printf(">> mouse %d %d\n", int(ev.mouse_x), int(ev.mouse_y))
	case .MOUSE_DOWN:
		fmt.printf(">> mousedown btn=%d %d %d\n", ev.mouse_button, int(ev.mouse_x), int(ev.mouse_y))
	case .MOUSE_UP:
		fmt.printf(">> mouseup btn=%d %d %d\n", ev.mouse_button, int(ev.mouse_x), int(ev.mouse_y))
	case .RESIZED:
		fmt.printf(">> resized sapp=%dx%d\n", sapp.width(), sapp.height())
	}
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	fmt.printf(">> clean exit after %v frames\n", state.frame_count)
}

// report_metrics prints the DPI-relevant picture once the window exists.
report_metrics :: proc() {
	display := (^xlib.Display)(sapp.x11_get_display())
	window := xlib.Window(uint(uintptr(sapp.x11_get_window())))

	phys_w, phys_h := xutil.window_px_size(display, window)

	xft := "unset"
	if res, found := xutil.resource_manager_string(display); found {
		defer delete(res)
		if value, ok := xutil.xft_dpi_value(res); ok {
			xft = fmt.tprintf("%.3f", value)
		}
	}
	mm := "unavailable"
	if dpi, ok := xutil.screen_dpi(display, 0); ok {
		mm = fmt.tprintf("%.1f", dpi)
	}

	fmt.printf(">> window=0x%x\n", uint(window))
	fmt.printf(">> physical=%dx%d sapp=%dx%d\n", phys_w, phys_h, sapp.width(), sapp.height())
	fmt.printf(">> dpi_scale=%.2f high_dpi=%t\n", sapp.dpi_scale(), sapp.high_dpi())
	fmt.printf(">> xft_dpi=%s mm_dpi=%s\n", xft, mm)
}

autoquit_frames_from_env :: proc() -> i64 {
	value, found := os.lookup_env("HAMMER_AUTOQUIT_FRAMES", context.temp_allocator)
	if !found {
		return 0
	}
	frames, ok := strconv.parse_i64(value)
	if !ok || frames <= 0 {
		return 0
	}
	return min(frames, 100_000_000)
}

high_dpi_from_env :: proc() -> bool {
	value, found := os.lookup_env("HAMMER_SPIKE_HIGH_DPI", context.temp_allocator)
	if !found {
		return false
	}
	return value == "1" || value == "true"
}

main :: proc() {
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		event_cb = event,
		cleanup_cb = cleanup,
		width = 400,
		height = 300,
		window_title = "hm-dpi-ime-spike",
		high_dpi = high_dpi_from_env(),
	})
}
