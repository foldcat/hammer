#+build linux

package main

import sapp "sokol:app"
import xlib "vendor:x11/xlib"

import "core/dpi"

X11_DPI :: struct {
	initialized:     bool,
	base_scale:      f32,
	reference_dpi:   f32,
	cached_scale:    f32,
	last_poll_frame: i64,
}

x11_dpi: X11_DPI

X11_DPI_POLL_FRAMES :: 15

foreign import xrandr "system:Xrandr"
@(default_calling_convention = "c", link_prefix = "XRR")
foreign xrandr {
	FreeMonitors :: proc(monitors: [^]xlib.XRRMonitorInfo, count: i32) ---
}

platform_dpi_scale :: proc() -> f32 {
	base := sapp.dpi_scale()
	if !x11_dpi.initialized {
		x11_dpi = X11_DPI{
			initialized = true,
			base_scale = base,
			cached_scale = base,
			last_poll_frame = -X11_DPI_POLL_FRAMES,
		}
	}
	if state.frame_count == x11_dpi.last_poll_frame ||
	   (state.frame_count > x11_dpi.last_poll_frame &&
		state.frame_count - x11_dpi.last_poll_frame < X11_DPI_POLL_FRAMES) {
		return x11_dpi.cached_scale
	}
	x11_dpi.last_poll_frame = state.frame_count

	current_dpi, ok := query_window_monitor_dpi()
	if !ok {
		return x11_dpi.cached_scale
	}
	if x11_dpi.reference_dpi <= 0 {
		x11_dpi.reference_dpi = current_dpi
	}
	if scale, valid := dpi.monitor_scale(x11_dpi.base_scale, x11_dpi.reference_dpi, current_dpi); valid {
		x11_dpi.cached_scale = scale
	}
	return x11_dpi.cached_scale
}

query_window_monitor_dpi :: proc() -> (f32, bool) {
	display := (^xlib.Display)(sapp.x11_get_display())
	window := xlib.Window(uint(uintptr(sapp.x11_get_window())))
	if display == nil || window == 0 {
		return 0, false
	}
	attributes: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(display, window, &attributes) == 0 || attributes.width <= 0 || attributes.height <= 0 {
		return 0, false
	}
	root := xlib.DefaultRootWindow(display)
	root_x, root_y: i32
	child: xlib.Window
	if !xlib.TranslateCoordinates(display, window, root, 0, 0, &root_x, &root_y, &child) {
		return 0, false
	}

	count: i32
	native := xlib.XRRGetMonitors(display, root, true, &count)
	if native == nil || count <= 0 || count > dpi.MAX_MONITORS {
		if native != nil {
			FreeMonitors(native, count)
		}
		return 0, false
	}
	defer FreeMonitors(native, count)

	monitors: [dpi.MAX_MONITORS]dpi.Monitor
	monitor_count := 0
	for index in 0 ..< int(count) {
		item := native[index]
		physical, valid := dpi.physical_dpi(item.width, item.mwidth)
		if !valid || item.width <= 0 || item.height <= 0 {
			continue
		}
		monitors[monitor_count] = dpi.Monitor{
			bounds = {x = item.x, y = item.y, width = item.width, height = item.height},
			dpi = physical,
		}
		monitor_count += 1
	}
	selected := dpi.select_monitor(
		dpi.Rect{x = root_x, y = root_y, width = attributes.width, height = attributes.height},
		monitors[:monitor_count],
	)
	if selected < 0 {
		return 0, false
	}
	return monitors[selected].dpi, true
}
