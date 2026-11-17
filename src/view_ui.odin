package main

import "core:fmt"
import "core:log"

import editing "core/editing"
import errs "core/errs"
import "core/ime"
import layout "core/layout"
import rope "core/rope"
import tagstate "core/tag"
import txn "core/txn"
import view "core/view"

editor_activate_window :: proc(window_id: layout.Window_ID) {
	if editor.active_window != window_id {
		editor.active_window = window_id
		editor.typing_group = 0
		ime.done(&state.preedit)
	}
	editor.active_text_kind = .Body
}

editor_activate_text :: proc(kind: Text_Kind, column_id := layout.Column_ID(0)) {
	if editor.active_text_kind != kind || editor.active_column != column_id {
		editor.typing_group = 0
		ime.done(&state.preedit)
	}
	editor.active_text_kind = kind
	editor.active_column = column_id
}

editor_active_view :: proc() -> ^view.View {
	item, _ := view.find(&editor.views, editor.active_window)
	return item
}

editor_active_tag :: proc() -> ^tagstate.State {
	switch editor.active_text_kind {
	case .Body:
		return nil
	case .Global_Tag:
		return &editor.global_tag
	case .Column_Tag:
		index, ok := layout.find_column(&editor.workspace, editor.active_column)
		if !ok {
			return nil
		}
		return &editor.column_tags[index]
	case .Window_Tag:
		item := editor_active_view()
		if item == nil {
			return nil
		}
		return &item.tag
	}
	return nil
}

editor_active_doc :: proc() -> ^txn.Doc {
	if tag := editor_active_tag(); tag != nil {
		return &tag.doc
	}
	return &editor.buffer.doc
}

editor_active_selection :: proc() -> ^txn.Selection {
	if tag := editor_active_tag(); tag != nil {
		return &tag.selection
	}
	item := editor_active_view()
	if item == nil {
		return nil
	}
	return &item.selection
}

editor_active_buffer_id :: proc() -> u64 {
	switch editor.active_text_kind {
	case .Body:
		return u64(editor.buffer.id)
	case .Global_Tag:
		return GLOBAL_TAG_BUFFER_ID
	case .Column_Tag:
		return COLUMN_TAG_BUFFER_BASE + u64(editor.active_column)
	case .Window_Tag:
		return WINDOW_TAG_BUFFER_BASE + u64(editor.active_window)
	}
	return 0
}

editor_active_delayed_paste :: proc() -> ^editing.Delayed_Paste {
	if tag := editor_active_tag(); tag != nil {
		return &tag.delayed_paste
	}
	item := editor_active_view()
	if item == nil {
		return nil
	}
	return &item.delayed_paste
}

editor_active_delayed_cut :: proc() -> ^editing.Delayed_Cut {
	if tag := editor_active_tag(); tag != nil {
		return &tag.delayed_cut
	}
	item := editor_active_view()
	if item == nil {
		return nil
	}
	return &item.delayed_cut
}

editor_finish_edit :: proc(item: ^view.View, previous_revision: u64, err: errs.Error) {
	if errs.ok(err) && item != nil && txn.doc_revision(&editor.buffer.doc) != previous_revision {
		current := editor.buffer.doc.current
		if current > 0 && int(current) <= len(editor.buffer.doc.log) {
			view.transform_after_edit(&editor.views, item.window_id, editor.buffer.doc.log[current - 1].ops)
		}
		editor_refresh_window_tags()
	}
	editor_report(err)
}

editor_finish_history_jump :: proc(item: ^view.View) {
	if item == nil {
		return
	}
	view.clamp_after_history_jump(&editor.views, item.window_id, rope.tree_byte_count(&editor.buffer.doc.tree))
	editor_refresh_window_tags()
}

editor_window_generated :: proc() -> string {
	name := "New"
	if editor.buffer.path != "" {
		name = editor.buffer.path
		for r, index in editor.buffer.path {
			if r == '/' || r == '\\' {
				name = editor.buffer.path[index + 1:]
			}
		}
	}
	commands := "Del"
	if editor_dirty() {
		commands = "Del Put"
	}
	return fmt.aprintf("%s %s | ", name, commands, allocator = context.temp_allocator)
}

editor_init_window_tag :: proc(item: ^view.View) -> errs.Error {
	return tagstate.init(&item.tag, editor_window_generated(), permanent())
}

editor_init_global_and_column_tags :: proc() -> errs.Error {
	if err := tagstate.init(&editor.global_tag, "New Col | ", permanent()); !errs.ok(err) {
		return err
	}
	for column_index in 0 ..< editor.workspace.column_count {
		if err := tagstate.init(&editor.column_tags[column_index], "New | ", permanent()); !errs.ok(err) {
			return err
		}
	}
	return {}
}

editor_refresh_window_tags :: proc() {
	generated := editor_window_generated()
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		previous_revision := txn.doc_revision(&item.tag.doc)
		editor_report(tagstate.refresh_generated(&item.tag, generated, permanent()))
		if txn.doc_revision(&item.tag.doc) != previous_revision {
			log.infof("tag: window %d generated %q", u64(item.window_id), generated)
		}
	}
}

editor_first_view :: proc() -> ^view.View {
	for index in 0 ..< view.MAX_VIEWS {
		if editor.views.views[index].window_id != 0 {
			return &editor.views.views[index]
		}
	}
	return nil
}
