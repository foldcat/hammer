package view

import editing "../editing"
import errs "../errs"
import layout "../layout"
import rope "../rope"
import tagstate "../tag"
import txn "../txn"

Buffer_ID :: distinct u64
MAX_VIEWS :: layout.MAX_COLUMNS * layout.MAX_WINDOWS_PER_COLUMN

View :: struct {
	window_id:     layout.Window_ID,
	buffer_id:     Buffer_ID,
	selection:     txn.Selection,
	first_line:    rope.Line_Index,
	tag:           tagstate.State,
	delayed_paste: editing.Delayed_Paste,
	delayed_cut:   editing.Delayed_Cut,
}

State :: struct {
	views:      [MAX_VIEWS]View,
	view_count: int,
}

add :: proc(state: ^State, window_id: layout.Window_ID, buffer_id: Buffer_ID) -> errs.Error {
	if state.view_count < 0 || state.view_count >= MAX_VIEWS {
		return errs.newf(.Resource_Limit, "view: at most %d views are supported", MAX_VIEWS)
	}
	if window_id == 0 || buffer_id == 0 {
		return errs.new(.Invalid_Input, "view: window and buffer IDs must be nonzero")
	}
	if _, found := find(state, window_id); found {
		return errs.new(.Conflict, "view: window already has a view")
	}
	for index in 0 ..< MAX_VIEWS {
		if state.views[index].window_id == 0 {
			state.views[index] = {window_id = window_id, buffer_id = buffer_id}
			state.view_count += 1
			return {}
		}
	}
	return errs.new(.Internal, "view: no stable slot is available")
}

find :: proc(state: ^State, window_id: layout.Window_ID) -> (^View, bool) {
	for index in 0 ..< MAX_VIEWS {
		if state.views[index].window_id == window_id {
			return &state.views[index], true
		}
	}
	return nil, false
}

// remove clears a stable slot without moving other views. The caller must
// cancel pending requests and destroy the tag document before removal.
remove :: proc(state: ^State, window_id: layout.Window_ID) -> bool {
	for index in 0 ..< MAX_VIEWS {
		if state.views[index].window_id != window_id {
			continue
		}
		state.views[index] = {}
		state.view_count -= 1
		return true
	}
	return false
}

buffer_view_count :: proc(state: ^State, buffer_id: Buffer_ID) -> int {
	count := 0
	for item in state.views {
		if item.window_id != 0 && item.buffer_id == buffer_id {
			count += 1
		}
	}
	return count
}

transform_after_edit :: proc(state: ^State, edited_window: layout.Window_ID, buffer_id: Buffer_ID, ops: []txn.Operation, byte_count: int) {
	for index in 0 ..< MAX_VIEWS {
		item := &state.views[index]
		if item.window_id == 0 || item.window_id == edited_window || item.buffer_id != buffer_id {
			continue
		}
		anchor := txn.Anchor{pos = item.selection.anchor, affinity = item.selection.affinity}
		active := txn.Anchor{pos = item.selection.active, affinity = item.selection.affinity}
		for op in ops {
			txn.anchor_apply_op(&anchor, op)
			txn.anchor_apply_op(&active, op)
		}
		item.selection.anchor = clamp(anchor.pos, 0, byte_count)
		item.selection.active = clamp(active.pos, 0, byte_count)
		item.selection.visual_column = 0
	}
}

clamp_after_history_jump :: proc(state: ^State, selected_window: layout.Window_ID, buffer_id: Buffer_ID, byte_count: int) {
	for index in 0 ..< MAX_VIEWS {
		item := &state.views[index]
		if item.window_id == 0 || item.window_id == selected_window || item.buffer_id != buffer_id {
			continue
		}
		item.selection.anchor = clamp(item.selection.anchor, 0, byte_count)
		item.selection.active = clamp(item.selection.active, 0, byte_count)
		item.selection.visual_column = 0
		if item.first_line < 0 {
			item.first_line = 0
		}
	}
}
