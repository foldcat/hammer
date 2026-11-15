#+build linux

package x11clipboard

import "base:runtime"
import "core:mem"
import "core:time"

import xlib "vendor:x11/xlib"

import platform "../../platform"
import errs "../../core/errs"

INCR_THRESHOLD :: 64 * 1024
INCR_CHUNK :: 64 * 1024
MAX_INCR_TRANSFERS :: 4
MAX_RESULTS :: 4
MAX_POLL_EVENTS :: 32
DEFAULT_TIMEOUT :: 10 * time.Second

Atoms :: struct {
	clipboard:         xlib.Atom,
	primary:           xlib.Atom,
	clipboard_manager: xlib.Atom,
	save_targets:      xlib.Atom,
	targets:           xlib.Atom,
	utf8:      xlib.Atom,
	gtk_utf8:  xlib.Atom,
	incr:      xlib.Atom,
	data_prop: xlib.Atom,
}

Options :: struct {
	allow_primary: bool,
	max_bytes:     int,
	timeout:       time.Duration,
	allocator:     runtime.Allocator,
}

Owned_Selection :: struct {
	id:     platform.Clipboard_Request_ID,
	active: bool,
	data:   []byte,
}

Read_Phase :: enum u8 {
	None,
	Notify,
	Incr,
}

Read_State :: struct {
	id:        platform.Clipboard_Request_ID,
	selection: platform.Clipboard_Selection,
	phase:     Read_Phase,
	deadline:  time.Time,
	expected:  u64,
	buf:       [dynamic]u8,
}

Incr_State :: struct {
	active:    bool,
	selection: platform.Clipboard_Selection,
	requestor: xlib.Window,
	property:  xlib.Atom,
	target:    xlib.Atom,
	pos:       int,
	data:      []byte, // owned for the transfer; independent of later writes
}

// State is single-threaded and fixed-location. Xlib display/window, owned
// payloads, read accumulation, and queued results all have matching destroy paths.
State :: struct {
	options:      Options,
	display:      ^xlib.Display,
	window:       xlib.Window,
	atoms:        Atoms,
	owned:        [2]Owned_Selection,
	read:         Read_State,
	incr:         [MAX_INCR_TRANSFERS]Incr_State,
	results:      [MAX_RESULTS]platform.Clipboard_Result,
	result_head:  int,
	result_count: int,
	initialized:  bool,
}

x_error_seen: bool
x_error_code: i32

on_x_error :: proc "c" (display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32 {
	x_error_seen = true
	x_error_code = i32(event.error_code)
	return 0
}

clear_x_error :: proc() {
	x_error_seen = false
	x_error_code = 0
}

sync_x_error :: proc(display: ^xlib.Display) -> bool {
	clear_x_error()
	xlib.Sync(display, false)
	return x_error_seen
}

init :: proc(state: ^State, options: Options) -> errs.Error {
	state.options = options
	if state.options.max_bytes == 0 {
		state.options.max_bytes = platform.DEFAULT_MAX_CLIPBOARD_BYTES
	}
	if state.options.timeout == 0 {
		state.options.timeout = DEFAULT_TIMEOUT
	}
	if state.options.allocator.procedure == nil {
		state.options.allocator = context.allocator
	}
	if state.options.max_bytes < 0 || state.options.max_bytes > int(max(u32)) || state.options.timeout < 0 {
		return errs.new(.Invalid_Input, "clipboard: invalid X11 limits", allocator = state.options.allocator)
	}

	xlib.SetErrorHandler(on_x_error)
	state.display = xlib.OpenDisplay(nil)
	if state.display == nil {
		return errs.new(.IO, "clipboard: XOpenDisplay failed", allocator = state.options.allocator)
	}
	if xlib.ImageByteOrder(state.display) != (xlib.ByteOrder.LSBFirst if ODIN_ENDIAN == .Little else xlib.ByteOrder.MSBFirst) {
		xlib.CloseDisplay(state.display)
		state.display = nil
		return errs.new(.Unsupported, "clipboard: X11 server byte order differs from the client", allocator = state.options.allocator)
	}
	state.window = xlib.CreateSimpleWindow(state.display, xlib.DefaultRootWindow(state.display), 0, 0, 1, 1, 0, 0, 0)
	if state.window == 0 {
		xlib.CloseDisplay(state.display)
		state.display = nil
		return errs.new(.IO, "clipboard: could not create the X11 clipboard window", allocator = state.options.allocator)
	}
	xlib.SelectInput(state.display, state.window, {.PropertyChange})
	state.atoms = {
		clipboard = xlib.InternAtom(state.display, cstring("CLIPBOARD"), false),
		primary = xlib.InternAtom(state.display, cstring("PRIMARY"), false),
		clipboard_manager = xlib.InternAtom(state.display, cstring("CLIPBOARD_MANAGER"), false),
		save_targets = xlib.InternAtom(state.display, cstring("SAVE_TARGETS"), false),
		targets = xlib.InternAtom(state.display, cstring("TARGETS"), false),
		utf8 = xlib.InternAtom(state.display, cstring("UTF8_STRING"), false),
		gtk_utf8 = xlib.InternAtom(state.display, cstring("text/plain;charset=utf-8"), false),
		incr = xlib.InternAtom(state.display, cstring("INCR"), false),
		data_prop = xlib.InternAtom(state.display, cstring("HAMMER_CLIPBOARD"), false),
	}
	if sync_x_error(state.display) {
		xlib.CloseDisplay(state.display)
		state.display = nil
		return errs.new(.IO, "clipboard: X11 initialization failed", allocator = state.options.allocator)
	}
	state.initialized = true
	return {}
}

destroy :: proc(state: ^State) {
	if state.display != nil {
		cancel_active_read(state)
		request_manager_handoff(state)
		for &owned in state.owned {
			delete(owned.data, allocator = state.options.allocator)
		}
		for &transfer in state.incr {
			if transfer.active {
				cancel_transfer(state, &transfer)
			}
		}
		for state.result_count > 0 {
			result, _ := pop_result(state)
			platform.result_destroy(&result)
		}
		xlib.CloseDisplay(state.display)
	}
	state^ = State{}
}

service :: proc() -> platform.Clipboard_Service {
	return {start = start, poll = poll, cancel = cancel}
}

start :: proc(user: rawptr, request: platform.Clipboard_Request) -> errs.Error {
	state := cast(^State)user
	if !state.initialized {
		return errs.new(.Invalid_Input, "clipboard: X11 service is not initialized", allocator = state.options.allocator)
	}
	if state.result_count > 0 {
		return errs.new(.Conflict, "clipboard: poll the completed result before starting another request", allocator = state.options.allocator)
	}
	if request.operation == .Read && state.read.phase != .None {
		return errs.new(.Conflict, "clipboard: an X11 read is already active", allocator = state.options.allocator)
	}
	if err := platform.validate_clipboard_request(request, state.options.allow_primary, state.options.max_bytes, allocator = state.options.allocator); !errs.ok(err) {
		return err
	}

	switch request.operation {
	case .Read:
		state.read.id = request.id
		state.read.selection = request.selection
		state.read.phase = .Notify
		state.read.deadline = time.time_add(time.now(), state.options.timeout)
		state.read.expected = 0
		state.read.buf = make([dynamic]u8, allocator = state.options.allocator)
		xlib.ConvertSelection(
			state.display,
			selection_atom(state, request.selection),
			state.atoms.utf8,
			state.atoms.data_prop,
			state.window,
			xlib.CurrentTime,
		)
		xlib.Flush(state.display)
		if sync_x_error(state.display) {
			cancel_active_read(state)
			return errs.new(.IO, "clipboard: X11 ConvertSelection failed", allocator = state.options.allocator)
		}
	case .Write:
		data, err := clone_bytes(request.data, allocator = state.options.allocator)
		if !errs.ok(err) {
			return err
		}
		index := selection_index(request.selection)
		xlib.SetSelectionOwner(state.display, selection_atom(state, request.selection), state.window, xlib.CurrentTime)
		if sync_x_error(state.display) || xlib.GetSelectionOwner(state.display, selection_atom(state, request.selection)) != state.window {
			delete(data, allocator = state.options.allocator)
			return errs.new(.IO, "clipboard: could not acquire X11 selection ownership", allocator = state.options.allocator)
		}
		delete(state.owned[index].data, allocator = state.options.allocator)
		state.owned[index] = {id = request.id, active = true, data = data}
		push_result(state, {
			id = request.id,
			selection = request.selection,
			operation = .Write,
			ownership = .Owned,
		})
	}
	return {}
}

poll :: proc(user: rawptr, allocator: runtime.Allocator) -> (platform.Clipboard_Result, bool) {
	state := cast(^State)user
	if !state.initialized {
		return {}, false
	}
	for _ in 0 ..< MAX_POLL_EVENTS {
		if xlib.Pending(state.display) == 0 {
			break
		}
		event: xlib.XEvent
		xlib.NextEvent(state.display, &event)
		#partial switch event.type {
		case .SelectionRequest:
			handle_selection_request(state, event.xselectionrequest)
		case .SelectionClear:
			handle_selection_clear(state, event.xselectionclear)
		case .SelectionNotify:
			handle_selection_notify(state, event.xselection, allocator)
		case .PropertyNotify:
			property := event.xproperty
			if state.read.phase == .Incr && property.window == state.window &&
				property.atom == state.atoms.data_prop && property.state == .PropertyNewValue {
				handle_incr_chunk(state, allocator)
			} else if property.state == .PropertyDelete {
				for &transfer in state.incr {
					if transfer.active && transfer.requestor == property.window && transfer.property == property.atom {
						incr_step(state, &transfer)
					}
				}
			}
		case:
		}
	}
	if state.read.phase != .None && i64(time.since(state.read.deadline)) >= 0 {
		finish_read(state, errs.new(.IO, "clipboard: timed out waiting for X11 selection data", allocator = allocator), allocator)
	}
	if state.result_count == 0 {
		return {}, false
	}
	return pop_result(state)
}

cancel :: proc(user: rawptr, id: platform.Clipboard_Request_ID) -> bool {
	state := cast(^State)user
	if state.read.phase == .None || state.read.id != id {
		return false
	}
	cancel_active_read(state)
	return true
}

cancel_active_read :: proc(state: ^State) {
	delete(state.read.buf)
	state.read = Read_State{}
}

selection_index :: proc(selection: platform.Clipboard_Selection) -> int {
	return 0 if selection == .Clipboard else 1
}

selection_atom :: proc(state: ^State, selection: platform.Clipboard_Selection) -> xlib.Atom {
	return state.atoms.clipboard if selection == .Clipboard else state.atoms.primary
}

push_result :: proc(state: ^State, result: platform.Clipboard_Result) {
	if state.result_count >= MAX_RESULTS {
		platform.result_destroy(&state.results[state.result_head])
		state.results[state.result_head] = {
			id = result.id,
			selection = result.selection,
			operation = result.operation,
			ownership = .Lost,
			err = errs.new(.Resource_Limit, "clipboard: X11 result queue overflow", allocator = result.allocator),
			allocator = result.allocator,
		}
		discarded := result
		platform.result_destroy(&discarded)
		return
	}
	index := (state.result_head + state.result_count) % MAX_RESULTS
	state.results[index] = result
	state.result_count += 1
}

pop_result :: proc(state: ^State) -> (platform.Clipboard_Result, bool) {
	if state.result_count == 0 {
		return {}, false
	}
	result := state.results[state.result_head]
	state.results[state.result_head] = {}
	state.result_head = (state.result_head + 1) % MAX_RESULTS
	state.result_count -= 1
	return result, true
}

clone_bytes :: proc(data: []byte, allocator: runtime.Allocator) -> ([]byte, errs.Error) {
	if len(data) == 0 {
		return {}, {}
	}
	clone, alloc_err := mem.alloc_bytes(len(data), 1, allocator)
	if alloc_err != .None {
		return {}, errs.new(.Resource_Limit, "clipboard: payload allocation failed", allocator = allocator)
	}
	copy(clone, data)
	return clone, {}
}
