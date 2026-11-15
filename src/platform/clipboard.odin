package platform

import "base:runtime"
import "core:unicode/utf8"

import errs "../core/errs"

DEFAULT_MAX_CLIPBOARD_BYTES :: 64 * 1024 * 1024

Clipboard_Selection :: enum u8 {
	Clipboard,
	Primary,
}

Clipboard_Operation :: enum u8 {
	Read,
	Write,
}

Clipboard_Request_ID :: distinct u64

// Clipboard_Request data is borrowed only during start. Native services clone
// write payloads before retaining them for later selection requests.
Clipboard_Request :: struct {
	id:        Clipboard_Request_ID,
	selection: Clipboard_Selection,
	operation: Clipboard_Operation,
	data:      []byte,
}

Clipboard_Ownership :: enum u8 {
	None,
	Owned,
	Lost,
}

// Clipboard_Result owns data and err. result_destroy releases both with their
// original allocators. Ownership Lost reports a later X11 SelectionClear for the
// write identified by id; it does not pretend the payload remains published.
Clipboard_Result :: struct {
	id:        Clipboard_Request_ID,
	selection: Clipboard_Selection,
	operation: Clipboard_Operation,
	ownership: Clipboard_Ownership,
	data:      []byte,
	err:       errs.Error,
	allocator: runtime.Allocator,
}

result_destroy :: proc(result: ^Clipboard_Result) {
	if result.data != nil {
		delete(result.data, result.allocator)
	}
	errs.destroy(&result.err)
	result^ = Clipboard_Result{}
}

// Clipboard_Service is polled on the UI thread. start never blocks waiting for
// clipboard contents. poll performs a bounded amount of native work and returns
// at most one owned result. cancel rejects later completion of the request.
Clipboard_Service :: struct {
	start:  proc(user: rawptr, request: Clipboard_Request) -> errs.Error,
	poll:   proc(user: rawptr, allocator: runtime.Allocator) -> (Clipboard_Result, bool),
	cancel: proc(user: rawptr, id: Clipboard_Request_ID) -> bool,
}

validate_clipboard_request :: proc(
	request: Clipboard_Request,
	allow_primary: bool,
	max_bytes: int,
	allocator := context.allocator,
) -> errs.Error {
	if request.id == 0 {
		return errs.new(.Invalid_Input, "clipboard: request ID must be nonzero", allocator = allocator)
	}
	if request.selection != .Clipboard && request.selection != .Primary {
		return errs.new(.Invalid_Input, "clipboard: invalid selection", allocator = allocator)
	}
	if request.selection == .Primary && !allow_primary {
		return errs.new(.Unsupported, "clipboard: PRIMARY support is disabled", allocator = allocator)
	}
	if max_bytes <= 0 {
		return errs.new(.Invalid_Input, "clipboard: invalid transfer budget", allocator = allocator)
	}
	switch request.operation {
	case .Read:
		if len(request.data) != 0 {
			return errs.new(.Invalid_Input, "clipboard: read request has a payload", allocator = allocator)
		}
	case .Write:
		if len(request.data) > max_bytes {
			return errs.new(.Resource_Limit, "clipboard: payload exceeds the transfer budget", allocator = allocator)
		}
		if !utf8.valid_string(string(request.data)) {
			return errs.new(.Invalid_Input, "clipboard: payload is not valid UTF-8", allocator = allocator)
		}
	case:
		return errs.new(.Invalid_Input, "clipboard: invalid operation", allocator = allocator)
	}
	return {}
}
