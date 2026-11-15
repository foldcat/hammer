// Package ime owns bounded, backend-free preedit state. Preedit is transient
// view state: it never changes a document. Committed text is dispatched
// separately through the editing transaction path.
package ime

import "base:runtime"
import "core:mem"
import "core:unicode/utf8"

import errs "../errs"

DEFAULT_MAX_PREEDIT_BYTES :: 64 * 1024

Options :: struct {
	max_bytes: int,
	allocator: runtime.Allocator,
}

// State is fixed-location and single-owner. Its text allocation is released by
// destroy. snapshot borrows text until the next update, done, cancel, or destroy.
State :: struct {
	text:        []byte,
	caret:       int,
	active:      bool,
	max_bytes:   int,
	allocator:   runtime.Allocator,
	initialized: bool,
}

Snapshot :: struct {
	text:   string,
	caret:  int,
	active: bool,
}

init :: proc(state: ^State, options: Options) -> errs.Error {
	if state == nil {
		return errs.new(.Invalid_Input, "ime: nil state")
	}
	if state.initialized {
		return errs.new(.Conflict, "ime: state is already initialized")
	}
	if options.max_bytes < 0 {
		return errs.new(.Invalid_Input, "ime: negative preedit limit")
	}
	state.max_bytes = options.max_bytes
	if state.max_bytes == 0 {
		state.max_bytes = DEFAULT_MAX_PREEDIT_BYTES
	}
	state.allocator = options.allocator
	if state.allocator.procedure == nil {
		state.allocator = context.allocator
	}
	state.initialized = true
	return {}
}

destroy :: proc(state: ^State) {
	if state == nil {
		return
	}
	if state.initialized && state.text != nil {
		delete(state.text, state.allocator)
	}
	state^ = State{}
}

begin :: proc(state: ^State, allocator := context.allocator) -> errs.Error {
	if state == nil || !state.initialized {
		return errs.new(.Invalid_Input, "ime: state is not initialized", allocator = allocator)
	}
	reset(state)
	state.active = true
	return {}
}

// update atomically replaces preedit text and its scalar-index caret. Invalid or
// oversized updates leave the previous snapshot unchanged.
update :: proc(state: ^State, text: []byte, caret: int, allocator := context.allocator) -> errs.Error {
	if state == nil || !state.initialized {
		return errs.new(.Invalid_Input, "ime: state is not initialized", allocator = allocator)
	}
	if !state.active {
		return errs.new(.Conflict, "ime: preedit draw without an active preedit", allocator = allocator)
	}
	if len(text) > state.max_bytes {
		return errs.newf(.Resource_Limit, "ime: preedit exceeds the %d-byte limit", state.max_bytes, allocator = allocator)
	}
	if !utf8.valid_string(string(text)) {
		return errs.new(.Invalid_Input, "ime: preedit is not valid UTF-8", allocator = allocator)
	}
	if caret < 0 || caret > utf8.rune_count_in_string(string(text)) {
		return errs.new(.Invalid_Input, "ime: preedit caret is outside the text", allocator = allocator)
	}

	replacement: []byte
	if len(text) > 0 {
		alloc_err: runtime.Allocator_Error
		replacement, alloc_err = mem.alloc_bytes(len(text), 1, state.allocator)
		if alloc_err != .None {
			return errs.newf(.Resource_Limit, "ime: allocating preedit failed: %v", alloc_err, allocator = allocator)
		}
		copy(replacement, text)
	}
	if state.text != nil {
		delete(state.text, state.allocator)
	}
	state.text = replacement
	state.caret = caret
	return {}
}

set_caret :: proc(state: ^State, caret: int, allocator := context.allocator) -> errs.Error {
	if state == nil || !state.initialized || !state.active {
		return errs.new(.Conflict, "ime: no active preedit", allocator = allocator)
	}
	if caret < 0 || caret > utf8.rune_count_in_bytes(state.text) {
		return errs.new(.Invalid_Input, "ime: preedit caret is outside the text", allocator = allocator)
	}
	state.caret = caret
	return {}
}

done :: proc(state: ^State) {
	if state != nil && state.initialized {
		reset(state)
	}
}

cancel :: proc(state: ^State) {
	done(state)
}

reset :: proc(state: ^State) {
	state.text = state.text[:0]
	state.caret = 0
	state.active = false
}

snapshot :: proc(state: ^State) -> Snapshot {
	if state == nil || !state.initialized {
		return {}
	}
	return Snapshot{text = string(state.text), caret = state.caret, active = state.active}
}
