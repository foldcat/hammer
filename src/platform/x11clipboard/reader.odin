#+build linux

package x11clipboard

import "base:runtime"
import "core:unicode/utf8"

import xlib "vendor:x11/xlib"

import platform "../../platform"
import errs "../../core/errs"

Property :: struct {
	actual_type:   xlib.Atom,
	actual_format: i32,
	nitems:        uint,
	bytes_after:   uint,
	data:          rawptr,
}

handle_selection_notify :: proc(state: ^State, event: xlib.XSelectionEvent, allocator: runtime.Allocator) {
	if state.read.phase != .Notify || event.requestor != state.window ||
		event.selection != selection_atom(state, state.read.selection) || event.target != state.atoms.utf8 {
		return
	}
	if event.property == xlib.None {
		finish_read(state, errs.new(.NotFound, "clipboard: selection has no owner or refused UTF-8 conversion", allocator = allocator), allocator)
		return
	}

	property, status := get_property(state, false)
	if status != 0 {
		finish_read(state, errs.new(.IO, "clipboard: XGetWindowProperty failed", allocator = allocator), allocator)
		return
	}
	if property.actual_type == state.atoms.incr {
		if property.actual_format != 32 || property.nitems != 1 || property.bytes_after != 0 {
			free_property(property)
			finish_read(state, errs.new(.Invalid_Input, "clipboard: malformed INCR announcement", allocator = allocator), allocator)
			return
		}
		expected := u64((([^]u32)(property.data))[0])
		free_property(property)
		if expected > u64(state.options.max_bytes) {
			finish_read(state, errs.new(.Resource_Limit, "clipboard: INCR announcement exceeds the transfer budget", allocator = allocator), allocator)
			return
		}
		state.read.expected = expected
		state.read.phase = .Incr
		xlib.DeleteProperty(state.display, state.window, state.atoms.data_prop)
		return
	}
	if property.actual_type != state.atoms.utf8 && property.actual_type != state.atoms.gtk_utf8 {
		free_property(property)
		finish_read(state, errs.new(.Unsupported, "clipboard: owner returned a non-UTF-8 property type", allocator = allocator), allocator)
		return
	}
	if property.actual_format != 8 || property.bytes_after != 0 || property.nitems > uint(state.options.max_bytes) {
		free_property(property)
		finish_read(state, errs.new(.Resource_Limit, "clipboard: direct property exceeds the supported size or format", allocator = allocator), allocator)
		return
	}
	append_err := append_property(state, property, allocator)
	free_property(property)
	xlib.DeleteProperty(state.display, state.window, state.atoms.data_prop)
	if !errs.ok(append_err) {
		finish_read(state, append_err, allocator)
		return
	}
	finish_read(state, {}, allocator)
}

handle_incr_chunk :: proc(state: ^State, allocator: runtime.Allocator) {
	property, status := get_property(state, true)
	if status != 0 {
		finish_read(state, errs.new(.IO, "clipboard: XGetWindowProperty failed during INCR", allocator = allocator), allocator)
		return
	}
	if property.actual_type != state.atoms.utf8 && property.actual_type != state.atoms.gtk_utf8 {
		free_property(property)
		finish_read(state, errs.new(.Unsupported, "clipboard: INCR chunk is not UTF-8 text", allocator = allocator), allocator)
		return
	}
	if property.actual_format != 8 || property.bytes_after != 0 {
		free_property(property)
		finish_read(state, errs.new(.Invalid_Input, "clipboard: malformed INCR chunk", allocator = allocator), allocator)
		return
	}
	if property.nitems == 0 {
		free_property(property)
		if state.read.expected != 0 && state.read.expected != u64(len(state.read.buf)) {
			finish_read(state, errs.new(.Invalid_Input, "clipboard: INCR size does not match its announcement", allocator = allocator), allocator)
			return
		}
		finish_read(state, {}, allocator)
		return
	}
	if state.read.expected != 0 && u64(len(state.read.buf)) + u64(property.nitems) > state.read.expected {
		free_property(property)
		finish_read(state, errs.new(.Invalid_Input, "clipboard: INCR stream exceeds its announcement", allocator = allocator), allocator)
		return
	}
	append_err := append_property(state, property, allocator)
	free_property(property)
	if !errs.ok(append_err) {
		finish_read(state, append_err, allocator)
	}
}

get_property :: proc(state: ^State, delete: bool) -> (Property, i32) {
	property: Property
	long_length := state.options.max_bytes / 4 + 2
	status := xlib.GetWindowProperty(
		state.display,
		state.window,
		state.atoms.data_prop,
		0,
		long_length,
		b32(delete),
		xlib.AnyPropertyType,
		&property.actual_type,
		&property.actual_format,
		&property.nitems,
		&property.bytes_after,
		&property.data,
	)
	return property, status
}

free_property :: proc(property: Property) {
	if property.data != nil {
		xlib.Free(property.data)
	}
}

append_property :: proc(state: ^State, property: Property, allocator: runtime.Allocator) -> errs.Error {
	count := int(property.nitems)
	if count > state.options.max_bytes - len(state.read.buf) {
		return errs.new(.Resource_Limit, "clipboard: input exceeds the transfer budget", allocator = allocator)
	}
	if reserve_err := reserve(&state.read.buf, len(state.read.buf) + count); reserve_err != .None {
		return errs.new(.Resource_Limit, "clipboard: growing the input buffer failed", allocator = allocator)
	}
	if count > 0 {
		data := ([^]u8)(property.data)
		append(&state.read.buf, ..data[:count])
	}
	return {}
}

finish_read :: proc(state: ^State, err: errs.Error, allocator: runtime.Allocator) {
	result := platform.Clipboard_Result {
		id = state.read.id,
		selection = state.read.selection,
		operation = .Read,
		err = err,
		allocator = allocator,
	}
	if errs.ok(result.err) {
		if !utf8.valid_string(string(state.read.buf[:])) {
			result.err = errs.new(.Invalid_Input, "clipboard: owner returned invalid UTF-8", allocator = allocator)
		} else {
			data, clone_err := clone_bytes(state.read.buf[:], allocator)
			result.data = data
			result.err = clone_err
		}
	}
	push_result(state, result)
	cancel_active_read(state)
}
