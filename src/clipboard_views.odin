package main

import "core:log"

import editing "core/editing"
import errs "core/errs"
import mouse "core/mouse"
import platform "platform"
import tagstate "core/tag"
import txn "core/txn"
import view "core/view"

editor_poll_view_clipboards :: proc(result: ^platform.Clipboard_Result) {
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		if editor_poll_body_clipboard(item, result) {
			return
		}
		if editor_poll_tag_clipboard(&item.tag, WINDOW_TAG_BUFFER_BASE + u64(item.window_id), result) {
			return
		}
	}
	if editor_poll_tag_clipboard(&editor.global_tag, GLOBAL_TAG_BUFFER_ID, result) {
		return
	}
	for column_index in 0 ..< editor.workspace.column_count {
		column := editor.workspace.columns[column_index]
		if editor_poll_tag_clipboard(&editor.column_tags[column_index], COLUMN_TAG_BUFFER_BASE + u64(column.id), result) {
			return
		}
	}
}

editor_poll_body_clipboard :: proc(item: ^view.View, result: ^platform.Clipboard_Result) -> bool {
	target_id := editor_body_target_id(item.window_id)
	if result.operation == .Read && item.delayed_paste.pending && item.delayed_paste.target.request_id == u64(result.id) {
		applied := false
		if !errs.ok(result.err) {
			editor_cancel_delayed_paste(&item.delayed_paste)
		} else {
			editor.typing_group = 0
			previous_revision := txn.doc_revision(&editor_buffer_for_view(item).doc)
			apply_err := editing.delayed_paste_apply(
				&item.delayed_paste,
				&editor_buffer_for_view(item).doc,
				&item.selection,
				u64(item.buffer_id),
				editor_buffer_for_view(item).generation,
				u64(result.id),
				result.data,
			)
			applied = errs.ok(apply_err)
			editor_finish_edit(item, previous_revision, apply_err)
		}
		editor_mouse_clipboard_result(target_id, result.id, result.operation, applied, editor_buffer_for_view(item).doc.current, len(result.data))
		return true
	}
	if result.operation == .Write && item.delayed_cut.pending && item.delayed_cut.target.request_id == u64(result.id) {
		applied := false
		if !errs.ok(result.err) {
			editor_cancel_delayed_cut(&item.delayed_cut)
		} else {
			editor.typing_group = 0
			previous_revision := txn.doc_revision(&editor_buffer_for_view(item).doc)
			apply_err := editing.delayed_cut_apply(
				&item.delayed_cut,
				&editor_buffer_for_view(item).doc,
				&item.selection,
				u64(item.buffer_id),
				editor_buffer_for_view(item).generation,
				u64(result.id),
			)
			applied = errs.ok(apply_err)
			editor_finish_edit(item, previous_revision, apply_err)
		}
		editor_mouse_clipboard_result(target_id, result.id, result.operation, applied, editor_buffer_for_view(item).doc.current, len(result.data))
		return true
	}
	return false
}

editor_poll_tag_clipboard :: proc(tag: ^tagstate.State, buffer_id: u64, result: ^platform.Clipboard_Result) -> bool {
	if result.operation == .Read && tag.delayed_paste.pending && tag.delayed_paste.target.request_id == u64(result.id) {
		applied := false
		if !errs.ok(result.err) {
			editor_cancel_delayed_paste(&tag.delayed_paste)
		} else {
			has_line_break := false
			for c in result.data {
				if c == '\n' || c == '\r' {
					has_line_break = true
					break
				}
			}
			if has_line_break {
				editor_cancel_delayed_paste(&tag.delayed_paste)
				log.warn("tag: newline input is not allowed")
			} else {
				editor.typing_group = 0
				apply_err := editing.delayed_paste_apply(
					&tag.delayed_paste,
					&tag.doc,
					&tag.selection,
					buffer_id,
					DEFAULT_BUFFER_GENERATION,
					u64(result.id),
					result.data,
				)
				applied = errs.ok(apply_err)
				editor_report(apply_err)
			}
		}
		editor_mouse_clipboard_result(mouse.Target_ID(buffer_id), result.id, result.operation, applied, tag.doc.current, len(result.data))
		return true
	}
	if result.operation == .Write && tag.delayed_cut.pending && tag.delayed_cut.target.request_id == u64(result.id) {
		applied := false
		if !errs.ok(result.err) {
			editor_cancel_delayed_cut(&tag.delayed_cut)
		} else {
			editor.typing_group = 0
			apply_err := editing.delayed_cut_apply(
				&tag.delayed_cut,
				&tag.doc,
				&tag.selection,
				buffer_id,
				DEFAULT_BUFFER_GENERATION,
				u64(result.id),
			)
			applied = errs.ok(apply_err)
			editor_report(apply_err)
		}
		editor_mouse_clipboard_result(mouse.Target_ID(buffer_id), result.id, result.operation, applied, tag.doc.current, len(result.data))
		return true
	}
	return false
}
