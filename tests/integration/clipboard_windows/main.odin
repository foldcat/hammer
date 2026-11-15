#+build windows

package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

import errs "hammer:core/errs"
import platform "hammer:platform"
import native "hammer:platform/winclipboard"

MAX_TRANSFER :: 4 * 1024 * 1024

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

client_init :: proc(client: ^Client) {
	native.init(&client.state, {max_bytes = MAX_TRANSFER, allocator = context.allocator})
	client.service = native.service()
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

self_test :: proc() {
	client: Client
	client_init(&client)
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

service_write :: proc(path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	require(read_err == nil, "could not read service-write input")
	defer delete(data)
	client: Client
	client_init(&client)
	defer native.destroy(&client.state)
	write(&client, 10, data)
}

service_read :: proc(path: string) {
	client: Client
	client_init(&client)
	defer native.destroy(&client.state)
	result := read(&client, 11)
	defer platform.result_destroy(&result)
	require(errs.ok(result.err), "service clipboard read failed")
	write_err := os.write_entire_file(path, result.data)
	require(write_err == nil, "could not write service-read output")
}

peer_open_clipboard :: proc() {
	opened := false
	for attempt in 0 ..< 5 {
		if windows.OpenClipboard(nil) != false {
			opened = true
			break
		}
		if attempt < 4 {
			windows.Sleep(2)
		}
	}
	require(opened, "peer OpenClipboard failed after bounded retries")
}

peer_write :: proc(path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	require(read_err == nil, "could not read peer-write input")
	defer delete(data)
	require(len(data) <= MAX_TRANSFER && utf8.valid_string(string(data)), "peer input is not bounded valid UTF-8")

	capacity := len(data) + 1
	allocation := windows.GlobalAlloc(windows.GMEM_MOVEABLE, uint(capacity * size_of(u16)))
	require(allocation != nil, "peer GlobalAlloc failed")
	memory := windows.HGLOBAL(allocation)
	owned_by_system := false
	defer if !owned_by_system {
		windows.GlobalFree(memory)
	}
	locked := windows.GlobalLock(memory)
	require(locked != nil, "peer GlobalLock failed")
	units := ([^]u16)(locked)[:capacity]
	count := utf16.encode_string(units, string(data))
	units[count] = 0
	windows.GlobalUnlock(memory)

	peer_open_clipboard()
	defer windows.CloseClipboard()
	require(windows.EmptyClipboard() != false, "peer EmptyClipboard failed")
	require(windows.SetClipboardData(windows.CF_UNICODETEXT, windows.HANDLE(memory)) != nil, "peer SetClipboardData failed")
	owned_by_system = true
}

peer_read :: proc(path: string) {
	peer_open_clipboard()
	defer windows.CloseClipboard()
	require(windows.IsClipboardFormatAvailable(windows.CF_UNICODETEXT) != false, "peer CF_UNICODETEXT is unavailable")
	handle := windows.GetClipboardData(windows.CF_UNICODETEXT)
	require(handle != nil, "peer GetClipboardData failed")
	size := windows.GlobalSize(handle)
	require(size % 2 == 0 && size / 2 <= MAX_TRANSFER, "peer clipboard size is invalid or exceeds its budget")
	unit_count := int(size / 2)
	if unit_count == 0 {
		require(os.write_entire_file(path, nil) == nil, "could not write empty peer-read output")
		return
	}
	locked := windows.GlobalLock(windows.HGLOBAL(handle))
	require(locked != nil, "peer GlobalLock failed")
	defer windows.GlobalUnlock(windows.HGLOBAL(handle))
	units := ([^]u16)(locked)[:unit_count]
	content_length := 0
	for content_length < len(units) && units[content_length] != 0 {
		content_length += 1
	}
	units = units[:content_length]
	data := make([]byte, len(units) * 4, context.allocator)
	defer delete(data)
	written := utf16.decode_to_utf8(data, units)
	require(utf8.valid_string(string(data[:written])), "peer produced invalid UTF-8")
	require(os.write_entire_file(path, data[:written]) == nil, "could not write peer-read output")
}

wait_for_owner_release :: proc() {
	fmt.println("ready clipboard owner")
	buffer: [1]u8
	for {
		count, err := os.read(os.stdin, buffer[:])
		if count == 0 || err != nil {
			return
		}
	}
}

usage :: proc() {
	fmt.eprintln("usage: clipboard_windows_test.exe [write|write-serve|read|peer-write|peer-write-serve|peer-read file]")
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		self_test()
		return
	}
	if len(args) != 2 {
		usage()
		os.exit(2)
	}
	switch args[0] {
	case "write":
		service_write(args[1])
	case "write-serve":
		service_write(args[1])
		wait_for_owner_release()
	case "read":
		service_read(args[1])
	case "peer-write":
		peer_write(args[1])
	case "peer-write-serve":
		peer_write(args[1])
		wait_for_owner_release()
	case "peer-read":
		peer_read(args[1])
	case:
		usage()
		os.exit(2)
	}
}
