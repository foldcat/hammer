package main

import errs "core/errs"
import "core/ime"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

editor_activate_window :: proc(window_id: layout.Window_ID) {
	if editor.active_window == window_id {
		return
	}
	editor.active_window = window_id
	editor.typing_group = 0
	ime.done(&state.preedit)
}

editor_active_view :: proc() -> ^view.View {
	item, _ := view.find(&editor.views, editor.active_window)
	return item
}

editor_active_selection :: proc() -> ^txn.Selection {
	item := editor_active_view()
	if item == nil {
		return nil
	}
	return &item.selection
}

editor_finish_edit :: proc(item: ^view.View, previous_revision: u64, err: errs.Error) {
	if errs.ok(err) && item != nil && txn.doc_revision(&editor.buffer.doc) != previous_revision {
		current := editor.buffer.doc.current
		if current > 0 && int(current) <= len(editor.buffer.doc.log) {
			view.transform_after_edit(&editor.views, item.window_id, editor.buffer.doc.log[current - 1].ops)
		}
	}
	editor_report(err)
}

editor_finish_history_jump :: proc(item: ^view.View) {
	if item == nil {
		return
	}
	view.clamp_after_history_jump(&editor.views, item.window_id, rope.tree_byte_count(&editor.buffer.doc.tree))
}
