package main

import "core:log"

import coords "core/coords"
import editing "core/editing"
import errs "core/errs"
import input "core/input"
import keybind "core/keybind"
import lifecycle "core/lifecycle"
import txn "core/txn"

Editor :: struct {
	doc:             txn.Doc,
	selection:       txn.Selection,
	saved_revision:  u64,
	typing_group:    u64,
	next_group:      u64,
	mouse_selecting: bool,
	close_guard:     lifecycle.Close_Guard,
}

editor: Editor

editor_init :: proc() -> errs.Error {
	if err := txn.doc_init(&editor.doc, {}, permanent()); !errs.ok(err) {
		return err
	}
	if err := lifecycle.close_guard_init(&editor.close_guard, {}, permanent()); !errs.ok(err) {
		txn.doc_destroy(&editor.doc)
		return err
	}
	return {}
}

editor_destroy :: proc() {
	lifecycle.close_guard_destroy(&editor.close_guard)
	txn.doc_destroy(&editor.doc)
	editor = {}
}

editor_consume_input :: proc(event: input.Event) {
	log_input_event(event)
	#partial switch e in event {
	case input.Pointer_Down:
		editor_pointer_down(e)
		return
	case input.Pointer_Move:
		editor_pointer_move(e)
		return
	case input.Pointer_Up:
		editor_pointer_up(e)
		return
	}
	editor_cancel_mouse_selection()

	action, ok := keybind.resolve_event(event)
	if !ok {
		return
	}

	if _, quitting := action.(keybind.Request_Quit); quitting {
		editor_request_close(.Quit, .Keyboard)
		return
	}
	if _, closing := action.(keybind.Close_Window); closing {
		editor_request_close(.Close_View, .Keyboard)
		return
	}
	editor_cancel_close_review()

	switch a in action {
	case editing.Insert_Text:
		editor_begin_typing_group()
		typed := a
		typed.grouping_key = editor.typing_group
		editor_perform(typed)
	case editing.Commit_Text:
		editor_begin_typing_group()
		committed := a
		committed.grouping_key = editor.typing_group
		editor_perform(committed)
	case editing.Move:
		editor.typing_group = 0
		editor_perform(a)
	case editing.Select_All:
		editor.typing_group = 0
		editor_perform(a)
	case editing.Delete_Backward:
		editor.typing_group = 0
		editor_perform(a)
	case editing.Delete_Forward:
		editor.typing_group = 0
		editor_perform(a)
	case keybind.Indent:
		editor.typing_group = 0
		editor_report(editing.indent(&editor.doc, &editor.selection, .Indent, {style = .Tabs}))
	case keybind.Outdent:
		editor.typing_group = 0
		editor_report(editing.indent(&editor.doc, &editor.selection, .Outdent, {style = .Tabs}))
	case keybind.Undo:
		editor.typing_group = 0
		selection, err := txn.doc_undo(&editor.doc)
		if errs.ok(err) {
			editor.selection = selection
		} else {
			if err.kind != .NotFound {
				log.warnf("edit: %v", errs.describe(err))
			}
			errs.destroy(&err)
		}
	case keybind.Redo:
		editor.typing_group = 0
		selection, err := txn.doc_redo(&editor.doc)
		if errs.ok(err) {
			editor.selection = selection
		} else {
			if err.kind != .NotFound {
				log.warnf("edit: %v", errs.describe(err))
			}
			errs.destroy(&err)
		}
	case keybind.Copy, keybind.Cut, keybind.Paste, keybind.Save, keybind.Save_As,
		keybind.Find, keybind.Open_Finder, keybind.Execute_Text, keybind.Look_Text:
		log.debugf("edit: action %T is not connected in this milestone", action)
	case keybind.Request_Quit, keybind.Close_Window:
	}
}

editor_pointer_down :: proc(event: input.Pointer_Down) {
	editor_cancel_mouse_selection()
	if event.button != .Left || .Ctrl in event.modifiers || .Alt in event.modifiers || .Super in event.modifiers {
		return
	}
	hit, ok := text_hit_test(event.pos, false)
	if !ok {
		return
	}
	editor.typing_group = 0
	editor_cancel_close_review()
	anchor := hit.offset
	if .Shift in event.modifiers {
		anchor = editor.selection.anchor
	}
	editor.selection = txn.Selection{anchor = anchor, active = hit.offset, affinity = hit.affinity}
	editor.mouse_selecting = true
}

editor_pointer_move :: proc(event: input.Pointer_Move) {
	if !editor.mouse_selecting {
		return
	}
	if .Left not_in event.buttons {
		editor_cancel_mouse_selection()
		return
	}
	editor_update_mouse_selection(event.pos)
}

editor_pointer_up :: proc(event: input.Pointer_Up) {
	if event.button == .Left && editor.mouse_selecting {
		editor_update_mouse_selection(event.pos)
	}
	editor_cancel_mouse_selection()
}

editor_update_mouse_selection :: proc(pos: coords.Logical_Point) {
	hit, ok := text_hit_test(pos, true)
	if !ok {
		return
	}
	editor.selection.active = hit.offset
	editor.selection.affinity = hit.affinity
	editor.selection.visual_column = 0
}

editor_cancel_mouse_selection :: proc() {
	editor.mouse_selecting = false
}

editor_perform :: proc(action: editing.Action) {
	editor_report(editing.perform(&editor.doc, &editor.selection, action))
}

editor_begin_typing_group :: proc() {
	if editor.typing_group != 0 {
		return
	}
	editor.next_group += 1
	if editor.next_group == 0 {
		editor.next_group = 1
	}
	editor.typing_group = editor.next_group
}

editor_dirty :: proc() -> bool {
	return txn.doc_revision(&editor.doc) != editor.saved_revision
}

editor_cancel_close_review :: proc() {
	phase := editor.close_guard.phase
	if phase != .Await_Decision && phase != .Reviewing && phase != .Saving && phase != .Save_Failed {
		return
	}
	editor_report(lifecycle.close_decision(&editor.close_guard, .Cancel))
}

editor_request_close :: proc(kind: lifecycle.Close_Kind, origin: lifecycle.Close_Origin) {
	editor_cancel_close_review()
	request := lifecycle.Close_Request{kind = kind, origin = origin, buffer_id = 1, buffer_generation = 1}
	if kind == .Quit {
		request.buffer_id = 0
		request.buffer_generation = 0
	}
	buffers := []lifecycle.Buffer_Snapshot{{
		id = 1,
		generation = 1,
		revision = txn.doc_revision(&editor.doc),
		view_count = 1,
		dirty = editor_dirty(),
	}}
	if err := lifecycle.close_request(&editor.close_guard, request, buffers); !errs.ok(err) {
		editor_report(err)
		return
	}
	if lifecycle.close_guard_ready(&editor.close_guard) {
		request_quit(.User_Request, "editor-close")
		return
	}
	log.warn("edit: unsaved text; close blocked until it is saved or explicitly discarded")
}

editor_report :: proc(err: errs.Error) {
	if errs.ok(err) {
		return
	}
	log.warnf("edit: %v", errs.describe(err))
	owned := err
	errs.destroy(&owned)
}
