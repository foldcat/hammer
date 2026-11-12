// Shared X11 probe helpers for the M00.05 DPI/IME spike.
//
// These helpers read the pieces of the X11 DPI story that the pinned
// sokol_app revision consumes (the Xft.dpi resource) and the pieces it
// ignores (the mm-based screen DPI, per-monitor RandR data). All returned
// strings are allocated in the caller's context.allocator and owned by
// the caller.
package xutil

import "core:strconv"
import "core:strings"

import xlib "vendor:x11/xlib"

// resource_manager_string returns the raw RESOURCE_MANAGER string of the
// root window, which is where Xrm consumers (and sapp's X11 backend)
// read Xft.dpi from. Owned by caller; delete when done.
resource_manager_string :: proc(display: ^xlib.Display) -> (string, bool) {
	atom := xlib.InternAtom(display, cstring("RESOURCE_MANAGER"), false)
	act_type: xlib.Atom
	act_format: i32
	nitems, bytes_after: uint
	props: rawptr
	status := xlib.GetWindowProperty(
		display,
		xlib.DefaultRootWindow(display),
		atom,
		0,
		1 << 20,
		false,
		xlib.AnyPropertyType,
		&act_type,
		&act_format,
		&nitems,
		&bytes_after,
		&props,
	)
	if status != 0 || act_format != 8 || nitems == 0 {
		if props != nil {
			xlib.Free(props)
		}
		return "", false
	}
	data := ([^]u8)(props)
	out, err := strings.clone(string(data[:nitems]), context.allocator)
	xlib.Free(props)
	if err != nil {
		return "", false
	}
	return out, true
}

// xft_dpi_value scans a RESOURCE_MANAGER string for an "Xft.dpi: <n>"
// entry and parses the value. Returns (value, found).
xft_dpi_value :: proc(res: string) -> (f64, bool) {
	remaining := res
	for {
		idx := strings.index_any(remaining, "Xx")
		if idx < 0 {
			return 0, false
		}
		rest := remaining[idx:]
		if len(rest) >= 7 && strings.equal_fold(rest[:7], "xft.dpi") {
			colon := strings.index_byte(rest, ':')
			if colon >= 0 {
				value, ok := strconv.parse_f64(strings.trim_space(rest[colon + 1:]))
				if ok {
					return value, true
				}
			}
			return 0, false
		}
		remaining = rest[1:]
	}
}

// screen_dpi computes the classic mm-based screen DPI (what a GLFW-style
// implementation would use). sapp's X11 backend deliberately does not use
// this; see docs/m00-05-dpi-ime.md.
screen_dpi :: proc(display: ^xlib.Display, screen: i32) -> (f64, bool) {
	mm := xlib.DisplayWidthMM(display, screen)
	if mm <= 0 {
		return 0, false
	}
	return f64(xlib.DisplayWidth(display, screen)) * 25.4 / f64(mm), true
}

// window_px_size returns the physical pixel size of a window.
window_px_size :: proc(display: ^xlib.Display, window: xlib.Window) -> (i32, i32) {
	attribs: xlib.XWindowAttributes
	xlib.GetWindowAttributes(display, window, &attribs)
	return attribs.width, attribs.height
}
