#+build linux

package x11clipboard

import xlib "vendor:x11/xlib"

import platform "../../platform"
import errs "../../core/errs"

handle_selection_clear :: proc(state: ^State, event: xlib.XSelectionClearEvent) {
	selection := platform.Clipboard_Selection.Clipboard
	if event.selection == state.atoms.primary {
		selection = .Primary
	} else if event.selection != state.atoms.clipboard {
		return
	}
	index := selection_index(selection)
	if !state.owned[index].active {
		return
	}
	id := state.owned[index].id
	delete(state.owned[index].data, state.options.allocator)
	state.owned[index] = {}
	for &transfer in state.incr {
		if transfer.active && transfer.selection == selection {
			cancel_transfer(state, &transfer)
		}
	}
	push_result(state, {
		id = id,
		selection = selection,
		operation = .Write,
		ownership = .Lost,
		allocator = state.options.allocator,
	})
}

handle_selection_request :: proc(state: ^State, request: xlib.XSelectionRequestEvent) {
	reply_property := xlib.Atom(xlib.None)
	property := request.property
	if property == xlib.None {
		property = request.target
	}
	selection := platform.Clipboard_Selection.Clipboard
	index := 0
	if request.selection == state.atoms.primary {
		selection = .Primary
		index = 1
	} else if request.selection != state.atoms.clipboard {
		index = -1
	}

	switch request.target {
	case state.atoms.targets:
		if index >= 0 && state.owned[index].active {
			targets := [3]xlib.Atom{state.atoms.targets, state.atoms.utf8, state.atoms.gtk_utf8}
			xlib.ChangeProperty(
				state.display,
				request.requestor,
				property,
				xlib.XA_ATOM,
				32,
				xlib.PropModeReplace,
				rawptr(&targets[0]),
				3,
			)
			reply_property = property
		}
	case state.atoms.utf8, state.atoms.gtk_utf8:
		if index >= 0 && state.owned[index].active {
			data := state.owned[index].data
			if len(data) <= INCR_THRESHOLD {
				payload: rawptr
				if len(data) > 0 {
					payload = raw_data(data)
				}
				xlib.ChangeProperty(
					state.display,
					request.requestor,
					property,
					request.target,
					8,
					xlib.PropModeReplace,
					payload,
					i32(len(data)),
				)
				reply_property = property
			} else {
				transfer := free_transfer(state)
				if transfer != nil {
					owned_data, clone_err := clone_bytes(data, state.options.allocator)
					if errs.ok(clone_err) {
						length := u32(len(data))
						xlib.ChangeProperty(
							state.display,
							request.requestor,
							property,
							state.atoms.incr,
							32,
							xlib.PropModeReplace,
							rawptr(&length),
							1,
						)
						xlib.SelectInput(state.display, request.requestor, {.PropertyChange})
						transfer^ = {
							active = true,
							selection = selection,
							requestor = request.requestor,
							property = property,
							target = request.target,
							data = owned_data,
						}
						reply_property = property
					} else {
						errs.destroy(&clone_err)
					}
				}
			}
		}
	case:
	}

	if x_error_seen {
		clear_x_error()
		reply_property = xlib.None
	}
	notify := xlib.XEvent{}
	notify.xselection.type = .SelectionNotify
	notify.xselection.display = state.display
	notify.xselection.requestor = request.requestor
	notify.xselection.selection = request.selection
	notify.xselection.target = request.target
	notify.xselection.property = reply_property
	notify.xselection.time = request.time
	xlib.SendEvent(state.display, request.requestor, false, {}, &notify)
	xlib.Flush(state.display)
}

free_transfer :: proc(state: ^State) -> ^Incr_State {
	for &transfer in state.incr {
		if !transfer.active {
			return &transfer
		}
	}
	return nil
}

incr_step :: proc(state: ^State, transfer: ^Incr_State) {
	remaining := len(transfer.data) - transfer.pos
	if remaining == 0 {
		xlib.ChangeProperty(
			state.display,
			transfer.requestor,
			transfer.property,
			transfer.target,
			8,
			xlib.PropModeReplace,
			nil,
			0,
		)
		cancel_transfer(state, transfer)
		return
	}
	count := min(remaining, INCR_CHUNK)
	xlib.ChangeProperty(
		state.display,
		transfer.requestor,
		transfer.property,
		transfer.target,
		8,
		xlib.PropModeAppend,
		raw_data(transfer.data[transfer.pos:]),
		i32(count),
	)
	transfer.pos += count
	if x_error_seen {
		clear_x_error()
		cancel_transfer(state, transfer)
	}
}

cancel_transfer :: proc(state: ^State, transfer: ^Incr_State) {
	delete(transfer.data, state.options.allocator)
	transfer^ = Incr_State{}
}
