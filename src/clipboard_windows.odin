#+build windows

package main

import winclipboard "platform/winclipboard"

native_clipboard: winclipboard.State

init_product_clipboard :: proc() {
	winclipboard.init(&native_clipboard, {allocator = permanent()})
	services.user = &native_clipboard
	services.clipboard = winclipboard.service()
}

cleanup_product_clipboard :: proc() {
	winclipboard.destroy(&native_clipboard)
	services.clipboard = {}
	services.user = nil
}
