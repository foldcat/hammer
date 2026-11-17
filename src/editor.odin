package main

import "core:log"
import "core:strings"

import coords "core/coords"
import editing "core/editing"
import errs "core/errs"
import filecodec "core/filecodec"
import fileload "core/fileload"
import filesave "core/filesave"
import input "core/input"
import keybind "core/keybind"
import layout "core/layout"
import lifecycle "core/lifecycle"
import platform "platform"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

DEFAULT_BUFFER_ID :: view.Buffer_ID(1)
DEFAULT_BUFFER_GENERATION :: u64(1)

Editor_Buffer :: struct {
	id:             view.Buffer_ID,
	generation:     u64,
	doc:            txn.Doc,
	path:           string,
	capture:        fileload.Capture,
	metadata:       filecodec.Metadata,
	saved_revision: u64,
}

Editor :: struct {
	buffer:                 Editor_Buffer,
	views:                  view.State,
	typing_group:           u64,
	next_group:             u64,
	next_clipboard_request: u64,
	mouse_selecting:        bool,
	workspace:              layout.Workspace,
	active_window:          layout.Window_ID,
	close_guard:            lifecycle.Close_Guard,
}

editor: Editor

editor_init :: proc(path := "") -> errs.Error {
	if path == "" {
		if err := txn.doc_init(&editor.buffer.doc, {}, permanent()); !errs.ok(err) {
			return err
		}
	} else {
		loaded: fileload.Loaded
		if err := fileload.load_file(&loaded, path, {}, context.temp_allocator); !errs.ok(err) {
			owned := errs.new(err.kind, err.message, allocator = permanent())
			errs.destroy(&err)
			return owned
		}
		defer fileload.loaded_destroy(&loaded)

		decoded := filecodec.decode_loaded(&loaded)
		if !filecodec.can_edit(decoded) {
			return errs.newf(
				.Unsupported,
				"file: %s is not valid editable UTF-8 (status %v)",
				path,
				decoded.status,
				allocator = permanent(),
			)
		}
		content, alloc_err := make([]byte, decoded.content.length, context.temp_allocator)
		if alloc_err != .None {
			return errs.newf(
				.Resource_Limit,
				"file: cannot allocate %d bytes for %s: %v",
				decoded.content.length,
				path,
				alloc_err,
				allocator = permanent(),
			)
		}
		defer delete(content, context.temp_allocator)
		it := filecodec.stream_iter_init(decoded.content)
		position := 0
		for {
			span, ok := filecodec.stream_iter_next(&it)
			if !ok {
				break
			}
			copy(content[position:], span)
			position += len(span)
		}
		if err := txn.doc_init_from_bytes(&editor.buffer.doc, content, {}, permanent()); !errs.ok(err) {
			return err
		}
		editor.buffer.capture = loaded.capture
		editor.buffer.metadata = decoded.metadata
		log.infof("file: opened %s (%d bytes)", path, decoded.content.length)
	}
	editor.buffer.id = DEFAULT_BUFFER_ID
	editor.buffer.generation = DEFAULT_BUFFER_GENERATION
	editor.buffer.path = strings.clone(path, permanent())
	if err := lifecycle.close_guard_init(&editor.close_guard, {}, permanent()); !errs.ok(err) {
		txn.doc_destroy(&editor.buffer.doc)
		return err
	}
	return editor_workspace_init()
}

editor_workspace_init :: proc() -> errs.Error {
	if err := layout.workspace_init(&editor.workspace); !errs.ok(err) {
		return err
	}
	left := editor.workspace.columns[0].id
	right, err := layout.add_column(&editor.workspace)
	if !errs.ok(err) {
		return err
	}
	if _, add_err := layout.add_window(&editor.workspace, left); !errs.ok(add_err) {
		return add_err
	}
	if _, add_err := layout.add_window(&editor.workspace, right); !errs.ok(add_err) {
		return add_err
	}
	for column_index in 0 ..< editor.workspace.column_count {
		column := &editor.workspace.columns[column_index]
		for placed in column.windows[:column.window_count] {
			if add_err := view.add(&editor.views, placed.id, editor.buffer.id); !errs.ok(add_err) {
				return add_err
			}
		}
	}
	editor.active_window = editor.workspace.columns[0].windows[0].id
	return {}
}

editor_destroy :: proc() {
	for index in 0 ..< editor.views.view_count {
		item := &editor.views.views[index]
		editor_cancel_delayed_paste(item)
		editor_cancel_delayed_cut(item)
	}
	lifecycle.close_guard_destroy(&editor.close_guard)
	txn.doc_destroy(&editor.buffer.doc)
	delete(editor.buffer.path, permanent())
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
	editor_cancel_pointer_gesture()

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
	case editing.Delete_Word_Backward:
		editor.typing_group = 0
		editor_perform(a)
	case editing.Delete_Forward:
		editor.typing_group = 0
		editor_perform(a)
	case keybind.Indent:
		editor.typing_group = 0
		previous_revision := txn.doc_revision(&editor.buffer.doc)
		editor_finish_edit(editor_active_view(), previous_revision, editing.indent(&editor.buffer.doc, editor_active_selection(), .Indent, {style = .Tabs}))
	case keybind.Outdent:
		editor.typing_group = 0
		previous_revision := txn.doc_revision(&editor.buffer.doc)
		editor_finish_edit(editor_active_view(), previous_revision, editing.indent(&editor.buffer.doc, editor_active_selection(), .Outdent, {style = .Tabs}))
	case keybind.Zoom_In:
		editor.typing_group = 0
		apply_text_zoom(.In)
	case keybind.Zoom_Out:
		editor.typing_group = 0
		apply_text_zoom(.Out)
	case keybind.Zoom_Reset:
		editor.typing_group = 0
		apply_text_zoom(.Reset)
	case keybind.Undo:
		editor.typing_group = 0
		selection, err := txn.doc_undo(&editor.buffer.doc)
		if errs.ok(err) {
			editor_active_selection()^ = selection
			editor_finish_history_jump(editor_active_view())
		} else {
			if err.kind != .NotFound {
				log.warnf("edit: %v", errs.describe(err))
			}
			errs.destroy(&err)
		}
	case keybind.Redo:
		editor.typing_group = 0
		selection, err := txn.doc_redo(&editor.buffer.doc)
		if errs.ok(err) {
			editor_active_selection()^ = selection
			editor_finish_history_jump(editor_active_view())
		} else {
			if err.kind != .NotFound {
				log.warnf("edit: %v", errs.describe(err))
			}
			errs.destroy(&err)
		}
	case keybind.Copy:
		editor.typing_group = 0
		editor_copy_selection()
	case keybind.Cut:
		editor.typing_group = 0
		editor_cut_selection()
	case keybind.Paste:
		editor.typing_group = 0
		editor_begin_paste()
	case keybind.Save:
		editor.typing_group = 0
		editor_save()
	case keybind.Save_As:
		log.debug("edit: Save As is deferred until tag commands can request a destination path")
	case keybind.Find, keybind.Open_Finder, keybind.Execute_Text, keybind.Look_Text:
		log.debugf("edit: action %T is not connected in this milestone", action)
	case keybind.Request_Quit, keybind.Close_Window:
	}
}

editor_copy_selection :: proc() {
	editor_poll_clipboard()
	item := editor_active_view()
	if item == nil {
		return
	}
	range := editing.selection_range(item.selection)
	if range.start == range.end {
		return
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return
	}
	request_id := editor_next_clipboard_request_id()
	editor_report(editor_start_clipboard_write(range, request_id))
}

editor_cut_selection :: proc() {
	editor_poll_clipboard()
	item := editor_active_view()
	if item == nil {
		return
	}
	range := editing.selection_range(item.selection)
	if range.start == range.end {
		return
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return
	}
	request_id := editor_next_clipboard_request_id()
	if err := editing.delayed_cut_begin(
		&item.delayed_cut,
		&editor.buffer.doc,
		&item.selection,
		u64(item.buffer_id),
		editor.buffer.generation,
		u64(request_id),
	); !errs.ok(err) {
		editor_report(err)
		return
	}
	if err := editor_start_clipboard_write(range, request_id); !errs.ok(err) {
		editor_cancel_delayed_cut(item)
		editor_report(err)
	}
}

editor_start_clipboard_write :: proc(
	range: rope.Byte_Range,
	request_id: platform.Clipboard_Request_ID,
) -> errs.Error {
	if range.end - range.start > platform.DEFAULT_MAX_CLIPBOARD_BYTES {
		return errs.new(.Resource_Limit, "clipboard: selection exceeds the transfer budget")
	}
	data, err := rope.tree_read_all(&editor.buffer.doc.tree, range, context.temp_allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(data, context.temp_allocator)
	return services.clipboard.start(services.user, {
		id = request_id,
		selection = .Clipboard,
		operation = .Write,
		data = data,
	})
}

editor_begin_paste :: proc() {
	editor_poll_clipboard()
	item := editor_active_view()
	if item == nil {
		return
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return
	}
	request_id := editor_next_clipboard_request_id()
	if err := editing.delayed_paste_begin(
		&item.delayed_paste,
		&editor.buffer.doc,
		&item.selection,
		u64(item.buffer_id),
		editor.buffer.generation,
		u64(request_id),
	); !errs.ok(err) {
		editor_report(err)
		return
	}
	if err := services.clipboard.start(services.user, {
		id = request_id,
		selection = .Clipboard,
		operation = .Read,
	}); !errs.ok(err) {
		editor_cancel_delayed_paste(item)
		editor_report(err)
	}
}

editor_poll_clipboard :: proc() {
	if services.clipboard.poll == nil {
		return
	}
	result, ok := services.clipboard.poll(services.user, permanent())
	if !ok {
		return
	}
	defer platform.result_destroy(&result)

	for index in 0 ..< editor.views.view_count {
		item := &editor.views.views[index]
		if result.operation == .Read && item.delayed_paste.pending &&
			item.delayed_paste.target.request_id == u64(result.id) {
			if !errs.ok(result.err) {
				editor_cancel_delayed_paste(item)
			} else {
				editor.typing_group = 0
				previous_revision := txn.doc_revision(&editor.buffer.doc)
				editor_finish_edit(item, previous_revision, editing.delayed_paste_apply(
					&item.delayed_paste,
					&editor.buffer.doc,
					&item.selection,
					u64(item.buffer_id),
					editor.buffer.generation,
					u64(result.id),
					result.data,
				))
			}
			break
		}
		if result.operation == .Write && item.delayed_cut.pending &&
			item.delayed_cut.target.request_id == u64(result.id) {
			if !errs.ok(result.err) {
				editor_cancel_delayed_cut(item)
			} else {
				editor.typing_group = 0
				previous_revision := txn.doc_revision(&editor.buffer.doc)
				editor_finish_edit(item, previous_revision, editing.delayed_cut_apply(
					&item.delayed_cut,
					&editor.buffer.doc,
					&item.selection,
					u64(item.buffer_id),
					editor.buffer.generation,
					u64(result.id),
				))
			}
			break
		}
	}
	if !errs.ok(result.err) {
		err := result.err
		result.err = {}
		editor_report(err)
	}
}

editor_cancel_delayed_paste :: proc(item: ^view.View) {
	if item == nil || !item.delayed_paste.pending {
		return
	}
	request_id := platform.Clipboard_Request_ID(item.delayed_paste.target.request_id)
	if services.clipboard.cancel != nil {
		services.clipboard.cancel(services.user, request_id)
	}
	editor_report(editing.delayed_paste_cancel(&item.delayed_paste, u64(request_id)))
}

editor_cancel_delayed_cut :: proc(item: ^view.View) {
	if item == nil || !item.delayed_cut.pending {
		return
	}
	request_id := item.delayed_cut.target.request_id
	editor_report(editing.delayed_cut_cancel(&item.delayed_cut, request_id))
}

editor_next_clipboard_request_id :: proc() -> platform.Clipboard_Request_ID {
	editor.next_clipboard_request += 1
	if editor.next_clipboard_request == 0 {
		editor.next_clipboard_request = 1
	}
	return platform.Clipboard_Request_ID(editor.next_clipboard_request)
}

editor_clipboard_available :: proc() -> bool {
	return services.clipboard.start != nil && services.clipboard.poll != nil && services.clipboard.cancel != nil
}

editor_pointer_down :: proc(event: input.Pointer_Down) {
	editor_cancel_pointer_gesture()
	if event.button != .Left || .Ctrl in event.modifiers || .Alt in event.modifiers || .Super in event.modifiers {
		return
	}
	geometry, _, geometry_ok := current_layout()
	if !geometry_ok {
		return
	}
	area := layout.hit_test(&geometry, event.pos)
	if area.kind == .Window_Control {
		editor_activate_window(area.window_id)
	}
	if layout.begin_drag(&editor.workspace, area, event.pos) {
		editor.typing_group = 0
		editor_cancel_close_review()
		return
	}
	if area.kind != .Body {
		return
	}
	editor_activate_window(area.window_id)
	item := editor_active_view()
	win, ok := window_for_id(&geometry, area.window_id)
	if !ok || item == nil {
		return
	}
	hit, hit_ok := text_hit_test(event.pos, false, win, item.first_line)
	if !hit_ok {
		return
	}
	editor.typing_group = 0
	editor_cancel_close_review()
	anchor := hit.offset
	if .Shift in event.modifiers {
		anchor = item.selection.anchor
	}
	item.selection = txn.Selection{anchor = anchor, active = hit.offset, affinity = hit.affinity}
	editor.mouse_selecting = true
}

editor_pointer_move :: proc(event: input.Pointer_Move) {
	if layout.dragging(&editor.workspace) {
		if .Left not_in event.buttons {
			layout.drag_cancel(&editor.workspace)
			return
		}
		layout.drag_move(&editor.workspace, event.pos)
		return
	}
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
	if event.button == .Left && layout.dragging(&editor.workspace) {
		kind := editor.workspace.drag.kind
		window_id := editor.workspace.drag.window_id
		column_id := editor.workspace.drag.column_id
		geometry, _, ok := current_layout()
		if ok {
			metrics := workspace_metrics()
			if layout.drag_end(&editor.workspace, &geometry, event.pos, metrics.drag_threshold) {
				editor_log_layout_drag(kind, column_id, window_id)
			}
		} else {
			layout.drag_cancel(&editor.workspace)
		}
		return
	}
	if event.button == .Left && editor.mouse_selecting {
		editor_update_mouse_selection(event.pos)
	}
	editor_cancel_mouse_selection()
}

editor_log_layout_drag :: proc(kind: layout.Drag_Kind, column_id: layout.Column_ID, window_id: layout.Window_ID) {
	switch kind {
	case .None:
	case .Column:
		index, ok := layout.find_column(&editor.workspace, column_id)
		if ok {
			column := editor.workspace.columns[index]
			log.infof("layout: column %d index %d weight %.4f", u64(column_id), index, column.weight)
		}
	case .Window:
		column_index, window_index, ok := layout.find_window(&editor.workspace, window_id)
		if ok {
			column := editor.workspace.columns[column_index]
			entry := column.windows[window_index]
			log.infof(
				"layout: window %d column %d index %d weight %.4f",
				u64(window_id),
				u64(column.id),
				window_index,
				entry.weight,
			)
		}
	}
}

editor_update_mouse_selection :: proc(pos: coords.Logical_Point) {
	item := editor_active_view()
	win, _, ok := current_window()
	if !ok || item == nil {
		return
	}
	hit, hit_ok := text_hit_test(pos, true, win, item.first_line)
	if !hit_ok {
		return
	}
	item.selection.active = hit.offset
	item.selection.affinity = hit.affinity
	item.selection.visual_column = 0
}

editor_cancel_mouse_selection :: proc() {
	editor.mouse_selecting = false
}

editor_cancel_pointer_gesture :: proc() {
	editor_cancel_mouse_selection()
	layout.drag_cancel(&editor.workspace)
}

editor_perform :: proc(action: editing.Action) {
	item := editor_active_view()
	previous_revision := txn.doc_revision(&editor.buffer.doc)
	editor_finish_edit(item, previous_revision, editing.perform_with_options(
		&editor.buffer.doc,
		editor_active_selection(),
		action,
		{autopair = cfg.Autopair, indent = {style = .Tabs}},
	))
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
	return txn.doc_revision(&editor.buffer.doc) != editor.buffer.saved_revision
}

editor_save :: proc() {
	if editor.buffer.path == "" {
		editor_report(errs.new(
			.Unsupported,
			"save: no file path; Save As requires a destination from tag commands",
			allocator = context.temp_allocator,
		))
		return
	}
	if !editor_dirty() {
		log.debugf("file: %s is already saved", editor.buffer.path)
		return
	}

	revision := txn.doc_revision(&editor.buffer.doc)
	result, err := filesave.save_tree(
		{tree = &editor.buffer.doc.tree, root = editor.buffer.doc.tree.root, revision = revision},
		editor.buffer.path,
		editor.buffer.metadata,
		{disk_check = .Unchanged, expected = editor.buffer.capture},
		context.temp_allocator,
	)
	if !errs.ok(err) {
		if result.replaced {
			log.error("file: save published the destination but did not complete; buffer remains dirty and must not be blindly retried")
		}
		editor_report(err)
		return
	}
	if result.revision != txn.doc_revision(&editor.buffer.doc) {
		editor_report(errs.new(
			.Conflict,
			"file: saved revision no longer matches the current buffer",
			allocator = context.temp_allocator,
		))
		return
	}
	editor.buffer.saved_revision = result.revision
	editor.buffer.capture = result.capture
	log.infof("file: saved %s (revision %d)", editor.buffer.path, result.revision)
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
	request := lifecycle.Close_Request {
		kind = kind,
		origin = origin,
		buffer_id = u64(editor.buffer.id),
		buffer_generation = editor.buffer.generation,
	}
	if kind == .Quit {
		request.buffer_id = 0
		request.buffer_generation = 0
	}
	buffers := []lifecycle.Buffer_Snapshot{{
		id = u64(editor.buffer.id),
		generation = editor.buffer.generation,
		revision = txn.doc_revision(&editor.buffer.doc),
		view_count = view.buffer_view_count(&editor.views, editor.buffer.id),
		dirty = editor_dirty(),
	}}
	if err := lifecycle.close_request(&editor.close_guard, request, buffers); !errs.ok(err) {
		editor_report(err)
		return
	}
	if lifecycle.close_guard_ready(&editor.close_guard) {
		if kind == .Close_View {
			editor_close_active_view()
		} else {
			request_quit(.User_Request, "editor-close")
		}
		return
	}
	log.warn("edit: unsaved text; close blocked until it is saved or explicitly discarded")
}

editor_close_active_view :: proc() {
	item := editor_active_view()
	if item == nil {
		return
	}
	if editor.views.view_count <= 1 {
		request_quit(.User_Request, "editor-close-last-view")
		return
	}
	window_id := item.window_id
	editor_cancel_delayed_paste(item)
	editor_cancel_delayed_cut(item)
	view.remove(&editor.views, window_id)
	layout.remove_window(&editor.workspace, window_id)
	next := editor_active_view()
	if next == nil && editor.views.view_count > 0 {
		editor_activate_window(editor.views.views[0].window_id)
	}
	editor_cancel_pointer_gesture()
	lifecycle.close_guard_reset(&editor.close_guard)
	log.infof("view: closed window %d; %d views remain", u64(window_id), editor.views.view_count)
}

editor_report :: proc(err: errs.Error) {
	if errs.ok(err) {
		return
	}
	log.warnf("edit: %v", errs.describe(err))
	owned := err
	errs.destroy(&owned)
}
