#+build linux

package x11clipboard

import "core:time"

import xlib "vendor:x11/xlib"

MANAGER_HANDOFF_TIMEOUT :: 250 * time.Millisecond

// request_manager_handoff asks an available X11 clipboard manager to preserve
// CLIPBOARD with SAVE_TARGETS. Absence/refusal is not an error: persistence is a
// session capability, and shutdown remains bounded.
request_manager_handoff :: proc(state: ^State) {
	if !state.owned[selection_index(.Clipboard)].active {
		return
	}
	if xlib.GetSelectionOwner(state.display, state.atoms.clipboard_manager) == 0 {
		return
	}
	clear_x_error()
	xlib.ConvertSelection(
		state.display,
		state.atoms.clipboard_manager,
		state.atoms.save_targets,
		state.atoms.data_prop,
		state.window,
		xlib.CurrentTime,
	)
	xlib.Flush(state.display)
	if x_error_seen {
		clear_x_error()
		return
	}

	deadline := time.time_add(time.now(), MANAGER_HANDOFF_TIMEOUT)
	for i64(time.since(deadline)) < 0 {
		if xlib.Pending(state.display) == 0 {
			time.sleep(time.Millisecond)
			continue
		}
		event: xlib.XEvent
		xlib.NextEvent(state.display, &event)
		#partial switch event.type {
		case .SelectionRequest:
			handle_selection_request(state, event.xselectionrequest)
		case .SelectionClear:
			handle_selection_clear(state, event.xselectionclear)
		case .SelectionNotify:
			notify := event.xselection
			if notify.requestor == state.window && notify.selection == state.atoms.clipboard_manager &&
				notify.target == state.atoms.save_targets {
				return
			}
		case .PropertyNotify:
			property := event.xproperty
			if property.state == .PropertyDelete {
				for &transfer in state.incr {
					if transfer.active && transfer.requestor == property.window && transfer.property == property.atom {
						incr_step(state, &transfer)
					}
				}
			}
		case:
		}
	}
}
