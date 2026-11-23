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
	item, found := view.find(&editor.views, window_id)
	if !found {
		return
	}
	buffer := editor_buffer_by_id(item.buffer_id)
	if buffer == nil {
		return
	}
	editor.buffer = buffer
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

editor_view_caret :: proc(item: ^view.View, doc: ^txn.Doc) -> int {
	if item == nil || doc == nil {
		return 0
	}
	if item.has_caret_override && item.caret_override_revision == txn.doc_revision(doc) &&
		item.caret_override_selection == item.selection {
		return clamp(item.caret_override, 0, rope.tree_byte_count(&doc.tree))
	}
	return item.selection.active
}

editor_active_tag :: proc() -> ^tagstate.State {
	switch editor.active_text_kind {
	case .Body:
		return nil
	case .Global_Tag:
		return &editor.global_tag
	case .Column_Tag:
		return editor_column_tag(editor.active_column)
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
	buffer := editor_buffer_for_view(item)
	if errs.ok(err) && buffer != nil && txn.doc_revision(&buffer.doc) != previous_revision {
		current := buffer.doc.current
		if current > 0 && int(current) <= len(buffer.doc.log) {
			view.transform_after_edit(&editor.views, item.window_id, item.buffer_id, buffer.doc.log[current - 1].ops, rope.tree_byte_count(&buffer.doc.tree))
		}
		editor_refresh_window_tags()
	}
	editor_report(err)
}

editor_finish_history_jump :: proc(item: ^view.View) {
	buffer := editor_buffer_for_view(item)
	if buffer == nil {
		return
	}
	view.clamp_after_history_jump(&editor.views, item.window_id, item.buffer_id, rope.tree_byte_count(&buffer.doc.tree))
	editor_refresh_window_tags()
}

// editor_tag_filepath_token reads the leftmost tag token. When ok is true the
// result is owned by the caller (temp allocator) and must be freed.
editor_tag_filepath_token :: proc(tag: ^tagstate.State, allocator := context.temp_allocator) -> (string, bool) {
	if tag == nil {
		return "", false
	}
	fp, fp_err := tagstate.filepath(tag, allocator)
	if !errs.ok(fp_err) {
		errs.destroy(&fp_err)
		return "", false
	}
	return fp, true
}

// editor_window_commands returns the generated command list for a window's tag.
// The result is a literal and is not owned by the caller.
editor_window_commands :: proc(buffer: ^Editor_Buffer, item: ^view.View) -> string {
	if buffer == nil {
		return "Del"
	}
	if buffer.has_conflict_pipe && buffer.conflict_pipe.state == .Conflict {
		return "Del Apply"
	}
	switch buffer.kind {
	case .Job_Output:
		return "Stop Del"
	case .Directory:
		return "Del Get"
	case .File:
		if txn.doc_revision(&buffer.doc) != buffer.saved_revision {
			return "Del Put"
		}
		if buffer.path == "" {
			// An untitled buffer whose leftmost token names the new file
			// offers Put so the file can be written.
			if fp, ok := editor_tag_filepath_token(&item.tag); ok {
				defer delete(fp, context.temp_allocator)
				if fp != "" && fp != "New" {
					return "Del Put"
				}
			}
		}
	case .Errors, .Commands, .Jobs, .Terminal:
	}
	return "Del"
}

editor_window_generated :: proc(item: ^view.View) -> string {
	buffer := editor_buffer_for_view(item)
	name := "New"
	typed := ""
	typed_owned := false
	if buffer != nil {
		switch buffer.kind {
		case .Errors:
			name = "+Errors"
		case .Job_Output:
			name = buffer.job_name
		case .Commands:
			name = "+Commands"
		case .Jobs:
			name = "+Jobs"
		case .Terminal:
			name = buffer.job_name
		case .Directory:
			if buffer.path != "" {
				name = buffer.path
			}
		case .File:
			if buffer.path != "" {
				name = buffer.path
				for r, index in buffer.path {
					if r == '/' || r == '\\' {
						name = buffer.path[index + 1:]
					}
				}
			} else if fp, ok := editor_tag_filepath_token(&item.tag); ok {
				typed = fp
				typed_owned = true
				if typed != "" {
					name = typed
				}
			}
		}
	}
	defer if typed_owned {
		delete(typed, context.temp_allocator)
	}
	return fmt.aprintf("%s %s | ", name, editor_window_commands(buffer, item), allocator = context.temp_allocator)
}

// editor_window_tag_locked reports whether the window's generated-commands
// region should be immutable. Blank (untitled) file buffers have no real
// filepath to protect, so their whole tag stays editable.
editor_window_tag_locked :: proc(item: ^view.View) -> bool {
	buffer := editor_buffer_for_view(item)
	if buffer == nil {
		return true
	}
	return !(buffer.kind == .File && buffer.path == "")
}

// editor_active_untitled_file reports whether the active window tag belongs to
// an untitled (blank) file buffer.
editor_active_untitled_file :: proc() -> bool {
	if editor.active_text_kind != .Window_Tag {
		return false
	}
	item := editor_active_view()
	if item == nil {
		return false
	}
	buffer := editor_buffer_for_view(item)
	return buffer != nil && buffer.kind == .File && buffer.path == ""
}

editor_init_window_tag :: proc(item: ^view.View) -> errs.Error {
	err := tagstate.init(&item.tag, editor_window_generated(item), permanent())
	if errs.ok(err) {
		item.tag.lock_commands = editor_window_tag_locked(item)
	}
	return err
}

editor_column_tag :: proc(column_id: layout.Column_ID) -> ^tagstate.State {
	if column_id == 0 {
		return nil
	}
	for index in 0 ..< layout.MAX_COLUMNS {
		if editor.column_tag_ids[index] == column_id {
			return &editor.column_tags[index]
		}
	}
	return nil
}

editor_init_column_tag :: proc(column_id: layout.Column_ID) -> errs.Error {
	if column_id == 0 || editor_column_tag(column_id) != nil {
		return errs.new(.Invalid_Input, "tag: invalid or duplicate column", allocator = permanent())
	}
	for index in 0 ..< layout.MAX_COLUMNS {
		if editor.column_tag_ids[index] != 0 {
			continue
		}
		if err := tagstate.init(&editor.column_tags[index], "New Delcol | ", permanent()); !errs.ok(err) {
			return err
		}
		editor.column_tag_ids[index] = column_id
		return {}
	}
	return errs.new(.Resource_Limit, "tag: no column tag slot is available", allocator = permanent())
}

editor_destroy_column_tag :: proc(column_id: layout.Column_ID) {
	for index in 0 ..< layout.MAX_COLUMNS {
		if editor.column_tag_ids[index] != column_id {
			continue
		}
		editor_cancel_tag_requests(&editor.column_tags[index])
		tagstate.destroy(&editor.column_tags[index])
		editor.column_tag_ids[index] = 0
		return
	}
}

editor_init_global_and_column_tags :: proc() -> errs.Error {
	if err := tagstate.init(&editor.global_tag, "Newcol Putall Cmds Wait Stop | ", permanent()); !errs.ok(err) {
		return err
	}
	for column_index in 0 ..< editor.workspace.column_count {
		if err := editor_init_column_tag(editor.workspace.columns[column_index].id); !errs.ok(err) {
			return err
		}
	}
	return {}
}

editor_refresh_window_tags :: proc() {
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		generated := editor_window_generated(item)
		previous_revision := txn.doc_revision(&item.tag.doc)
		editor_report(tagstate.refresh_generated(&item.tag, generated, permanent()))
		item.tag.lock_commands = editor_window_tag_locked(item)
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
