#+build linux

package main

import "core:log"

import "core/errs"
import x11clipboard "platform/x11clipboard"

native_clipboard: x11clipboard.State

init_product_clipboard :: proc() {
	err := x11clipboard.init(&native_clipboard, {allocator = permanent()})
	if !errs.ok(err) {
		log.warnf("clipboard: X11 service unavailable: %v", errs.describe(err))
		errs.destroy(&err)
		return
	}
	services.user = &native_clipboard
	services.clipboard = x11clipboard.service()
}

cleanup_product_clipboard :: proc() {
	x11clipboard.destroy(&native_clipboard)
	services.clipboard = {}
	services.user = nil
}
