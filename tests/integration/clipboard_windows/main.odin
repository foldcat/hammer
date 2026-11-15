#+build windows

package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:sys/windows"

import errs "hammer:core/errs"
import platform "hammer:platform"
import native "hammer:platform/winclipboard"

Client :: struct {
	state:   native.State,
	service: platform.Clipboard_Service,
}

require :: proc(condition: bool, message: string) {
	if !condition {
		fmt.eprintln(message)
		os.exit(1)
	}
}

start :: proc(client: ^Client, request: platform.Clipboard_Request) {
	err := client.service.start(&client.state, request)
	defer errs.destroy(&err)
	require(errs.ok(err), "clipboard start failed")
}

next :: proc(client: ^Client) -> platform.Clipboard_Result {
	result, ok := client.service.poll(&client.state, context.allocator)
	require(ok, "clipboard result missing")
	return result
}

write :: proc(client: ^Client, id: platform.Clipboard_Request_ID, data: []byte) {
	start(client, {id = id, operation = .Write, data = data})
	result := next(client)
	defer platform.result_destroy(&result)
	require(result.id == id && result.ownership == .Owned && errs.ok(result.err), "clipboard write failed")
}

read :: proc(client: ^Client, id: platform.Clipboard_Request_ID) -> platform.Clipboard_Result {
	start(client, {id = id, operation = .Read})
	return next(client)
}

main :: proc() {
	client: Client
	native.init(&client.state, {max_bytes = 1024 * 1024, allocator = context.allocator})
	client.service = native.service()
	defer native.destroy(&client.state)

	unicode := transmute([]byte)string("ASCII é Ελληνικά кириллица 漢字 A\u0301 😀 עברית")
	write(&client, 1, unicode)
	result := read(&client, 2)
	require(errs.ok(result.err) && bytes.equal(result.data, unicode), "Unicode clipboard round-trip failed")
	platform.result_destroy(&result)

	write(&client, 3, nil)
	empty := read(&client, 4)
	require(errs.ok(empty.err) && len(empty.data) == 0, "empty clipboard round-trip failed")
	platform.result_destroy(&empty)

	payload := make([]byte, 256 * 1024)
	defer delete(payload)
	for &b in payload {
		b = 'x'
	}
	copy(payload, "中😀")
	write(&client, 5, payload)
	large := read(&client, 6)
	require(errs.ok(large.err) && bytes.equal(large.data, payload), "large clipboard round-trip failed")
	platform.result_destroy(&large)

	require(windows.OpenClipboard(nil) != false, "OpenClipboard failed")
	units := [2]u16{0xd800, 0}
	allocation := windows.GlobalAlloc(windows.GMEM_MOVEABLE, size_of(units))
	require(allocation != nil, "GlobalAlloc failed")
	native_memory := windows.HGLOBAL(allocation)
	locked := windows.GlobalLock(native_memory)
	require(locked != nil, "GlobalLock failed")
	copy(([^]u16)(locked)[:len(units)], units[:])
	windows.GlobalUnlock(native_memory)
	require(windows.EmptyClipboard() != false, "EmptyClipboard failed")
	require(windows.SetClipboardData(windows.CF_UNICODETEXT, windows.HANDLE(native_memory)) != nil, "SetClipboardData failed")
	windows.CloseClipboard()
	invalid := read(&client, 7)
	require(invalid.err.kind == .Invalid_Input, "unpaired UTF-16 was not rejected")
	platform.result_destroy(&invalid)

	primary_err := client.service.start(&client.state, {id = 8, selection = .Primary, operation = .Read})
	require(primary_err.kind == .Unsupported, "PRIMARY should be unsupported on Windows")
	errs.destroy(&primary_err)
	fmt.println("clipboard-windows: Unicode, empty, 256 KiB, invalid UTF-16, and PRIMARY policy checks passed")
}
