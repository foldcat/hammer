#+build linux

package main

import "core:log"

import sapp "sokol:app"
import xlib "vendor:x11/xlib"

import "core/errs"
import x11ime "platform/x11ime"

native_ime: x11ime.State

init_product_ime :: proc() {
	display := (^xlib.Display)(sapp.x11_get_display())
	window := xlib.Window(uint(uintptr(sapp.x11_get_window())))
	err := x11ime.init(&native_ime, display, window, {
		allocator = permanent(),
		service = services.ime,
		user = services.user,
	})
	if err.kind == .None {
		x11ime.set_event_filter(product_ime_filter)
		log.infof("ime: X11 input context active (style=0x%x)", native_ime.style)
		return
	}
	log.warnf("ime: X11 initialization failed; using ordinary Sokol text input: %v", err.message)
	errs.destroy(&err)
}

cleanup_product_ime :: proc() {
	x11ime.set_event_filter(nil)
	x11ime.destroy(&native_ime)
}

product_ime_filter :: proc "c" (event: ^xlib.XEvent) -> i32 {
	context = app_context()
	return x11ime.filter_event(&native_ime, event)
}

