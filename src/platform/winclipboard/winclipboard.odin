#+build windows

package winclipboard

import "base:runtime"
import "core:mem"
import "core:sys/windows"
import "core:time"
import "core:unicode/utf16"
import "core:unicode/utf8"

import platform "../../platform"
import errs "../../core/errs"

DEFAULT_OPEN_RETRIES :: 5
DEFAULT_RETRY_DELAY :: 2 * time.Millisecond

Options :: struct {
	max_bytes:   int,
	open_retries: int,
	retry_delay: time.Duration,
	allocator:   runtime.Allocator,
}

// State is single-owner and fixed-location. pending_units is copied from the
// system clipboard and released after conversion during poll.
State :: struct {
	options:        Options,
	base:           platform.Clipboard_Result,
	result_error:   errs.Error,
	pending_units:  []u16,
	has_result:     bool,
	has_text:       bool,
}

init :: proc(state: ^State, options: Options) {
	state.options = options
	if state.options.max_bytes == 0 {
		state.options.max_bytes = platform.DEFAULT_MAX_CLIPBOARD_BYTES
	}
	if state.options.open_retries <= 0 {
		state.options.open_retries = DEFAULT_OPEN_RETRIES
	}
	if state.options.retry_delay <= 0 {
		state.options.retry_delay = DEFAULT_RETRY_DELAY
	}
	if state.options.allocator.procedure == nil {
		state.options.allocator = context.allocator
	}
}

destroy :: proc(state: ^State) {
	delete(state.pending_units, state.options.allocator)
	errs.destroy(&state.result_error)
	state^ = State{}
}

service :: proc() -> platform.Clipboard_Service {
	return {start = start, poll = poll, cancel = cancel}
}

start :: proc(user: rawptr, request: platform.Clipboard_Request) -> errs.Error {
	state := cast(^State)user
	if state.has_result {
		return errs.new(.Conflict, "clipboard: a Windows result is still pending")
	}
	if err := platform.validate_clipboard_request(request, false, state.options.max_bytes); !errs.ok(err) {
		return err
	}

	state.base = {
		id = request.id,
		selection = request.selection,
		operation = request.operation,
		ownership = .Owned if request.operation == .Write else .None,
	}
	state.has_result = true
	switch request.operation {
	case .Read:
		state.result_error = read_clipboard(state, request)
	case .Write:
		state.result_error = write_clipboard(state, request.data)
	}
	return {}
}

poll :: proc(user: rawptr, allocator: runtime.Allocator) -> (platform.Clipboard_Result, bool) {
	state := cast(^State)user
	if !state.has_result {
		return {}, false
	}
	result := state.base
	result.allocator = allocator
	result.err = state.result_error
	state.result_error = {}
	if state.has_text && errs.ok(result.err) {
		data, err := utf16_to_utf8(state.pending_units, allocator)
		if !errs.ok(err) {
			result.err = err
		} else {
			result.data = data
		}
	}
	delete(state.pending_units, state.options.allocator)
	state.pending_units = nil
	state.has_text = false
	state.has_result = false
	state.base = {}
	return result, true
}

cancel :: proc(user: rawptr, id: platform.Clipboard_Request_ID) -> bool {
	state := cast(^State)user
	if !state.has_result || state.base.id != id {
		return false
	}
	delete(state.pending_units, state.options.allocator)
	state.pending_units = nil
	state.has_text = false
	errs.destroy(&state.result_error)
	state.base = {}
	state.has_result = false
	return true
}

open_clipboard :: proc(state: ^State) -> bool {
	for attempt in 0 ..< state.options.open_retries {
		if windows.OpenClipboard(nil) {
			return true
		}
		if attempt + 1 < state.options.open_retries {
			windows.Sleep(windows.DWORD(state.options.retry_delay / time.Millisecond))
		}
	}
	return false
}

read_clipboard :: proc(state: ^State, request: platform.Clipboard_Request) -> errs.Error {
	if !open_clipboard(state) {
		return errs.new(.IO, "clipboard: OpenClipboard failed after bounded retries", allocator = state.options.allocator)
	}
	defer windows.CloseClipboard()

	if !windows.IsClipboardFormatAvailable(windows.CF_UNICODETEXT) {
		if windows.CountClipboardFormats() == 0 {
			state.has_text = true
			return {}
		}
		return errs.new(.Unsupported, "clipboard: CF_UNICODETEXT is unavailable", allocator = state.options.allocator)
	}
	handle := windows.GetClipboardData(windows.CF_UNICODETEXT)
	if handle == nil {
		return errs.new(.IO, "clipboard: GetClipboardData(CF_UNICODETEXT) failed", allocator = state.options.allocator)
	}
	size := windows.GlobalSize(handle)
	if size % 2 != 0 {
		return errs.new(.Invalid_Input, "clipboard: CF_UNICODETEXT has an odd byte size", allocator = state.options.allocator)
	}
	unit_count := int(size / 2)
	if unit_count > state.options.max_bytes {
		return errs.new(.Resource_Limit, "clipboard: UTF-16 input exceeds the transfer budget", allocator = state.options.allocator)
	}
	if unit_count == 0 {
		state.has_text = true
		return {}
	}
	locked := windows.GlobalLock(windows.HGLOBAL(handle))
	if locked == nil {
		return errs.new(.IO, "clipboard: GlobalLock failed while reading text", allocator = state.options.allocator)
	}
	defer windows.GlobalUnlock(windows.HGLOBAL(handle))

	units := ([^]u16)(locked)[:unit_count]
	content_length := 0
	for content_length < len(units) && units[content_length] != 0 {
		content_length += 1
	}
	units = units[:content_length]
	if _, err := utf16_measure(units, state.options.max_bytes, allocator = state.options.allocator); !errs.ok(err) {
		return err
	}
	state.pending_units = make([]u16, len(units), allocator = state.options.allocator)
	copy(state.pending_units, units)
	state.has_text = true
	return {}
}

write_clipboard :: proc(state: ^State, text: []byte) -> errs.Error {
	capacity := len(text) + 1
	allocation := windows.GlobalAlloc(windows.GMEM_MOVEABLE, uint(capacity * size_of(u16)))
	if allocation == nil {
		return errs.new(.Resource_Limit, "clipboard: GlobalAlloc failed", allocator = state.options.allocator)
	}
	native := windows.HGLOBAL(allocation)
	owned_by_system := false
	defer if !owned_by_system {
		windows.GlobalFree(native)
	}

	locked := windows.GlobalLock(native)
	if locked == nil {
		return errs.new(.IO, "clipboard: GlobalLock failed while writing text", allocator = state.options.allocator)
	}
	units := ([^]u16)(locked)[:capacity]
	count := utf16.encode_string(units, string(text))
	units[count] = 0
	windows.GlobalUnlock(native)

	if !open_clipboard(state) {
		return errs.new(.IO, "clipboard: OpenClipboard failed after bounded retries", allocator = state.options.allocator)
	}
	defer windows.CloseClipboard()
	if !windows.EmptyClipboard() {
		return errs.new(.IO, "clipboard: EmptyClipboard failed", allocator = state.options.allocator)
	}
	if windows.SetClipboardData(windows.CF_UNICODETEXT, windows.HANDLE(native)) == nil {
		return errs.new(.IO, "clipboard: SetClipboardData failed", allocator = state.options.allocator)
	}
	owned_by_system = true
	return {}
}

utf16_measure :: proc(units: []u16, max_bytes: int, allocator: runtime.Allocator) -> (int, errs.Error) {
	byte_count := 0
	for index := 0; index < len(units); index += 1 {
		r := rune(units[index])
		if r >= 0xd800 && r <= 0xdbff {
			if index + 1 >= len(units) || units[index + 1] < 0xdc00 || units[index + 1] > 0xdfff {
				return 0, errs.new(.Invalid_Input, "clipboard: unpaired UTF-16 high surrogate", allocator = allocator)
			}
			index += 1
			r = 0x10000
		} else if r >= 0xdc00 && r <= 0xdfff {
			return 0, errs.new(.Invalid_Input, "clipboard: unpaired UTF-16 low surrogate", allocator = allocator)
		}
		_, width := utf8.encode_rune(r)
		if byte_count + width > max_bytes {
			return 0, errs.new(.Resource_Limit, "clipboard: UTF-8 result exceeds the transfer budget", allocator = allocator)
		}
		byte_count += width
	}
	return byte_count, {}
}

utf16_to_utf8 :: proc(units: []u16, allocator: runtime.Allocator) -> ([]byte, errs.Error) {
	byte_count, err := utf16_measure(units, platform.DEFAULT_MAX_CLIPBOARD_BYTES, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	if byte_count == 0 {
		return {}, {}
	}
	data, alloc_err := mem.alloc_bytes(byte_count, 1, allocator)
	if alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "clipboard: allocating UTF-8 result failed", allocator = allocator)
	}
	written := utf16.decode_to_utf8(data, units)
	return data[:written], {}
}
