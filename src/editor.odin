package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import address "core/address"
import command "core/command"
import directory "core/directory"
import edit "core/edit"
import editing "core/editing"
import errs "core/errs"
import filecodec "core/filecodec"
import fileload "core/fileload"
import filesave "core/filesave"
import input "core/input"
import keybind "core/keybind"
import layout "core/layout"
import lifecycle "core/lifecycle"
import mouse "core/mouse"
import platform "platform"
import rope "core/rope"
import scroll "core/scroll"
import tagstate "core/tag"
import txn "core/txn"
import view "core/view"

DEFAULT_BUFFER_ID :: view.Buffer_ID(1)
DEFAULT_BUFFER_GENERATION :: u64(1)
GLOBAL_TAG_BUFFER_ID :: u64(2)
COLUMN_TAG_BUFFER_BASE :: u64(1000)
WINDOW_TAG_BUFFER_BASE :: u64(2000)

Text_Kind :: command.Source_Kind

Buffer_Kind :: enum u8 {
	File,
	Directory,
	Errors,
}

Editor_Buffer :: struct {
	id:             view.Buffer_ID,
	generation:     u64,
	kind:           Buffer_Kind,
	doc:            txn.Doc,
	path:           string,
	capture:        fileload.Capture,
	metadata:       filecodec.Metadata,
	saved_revision: u64,
	regex_history:  address.Regex_History,
}

Editor :: struct {
	buffers:                [view.MAX_VIEWS]Editor_Buffer,
	buffer_count:           int,
	next_buffer_id:         u64,
	buffer:                 ^Editor_Buffer,
	views:                  view.State,
	global_tag:             tagstate.State,
	column_tags:            [layout.MAX_COLUMNS]tagstate.State,
	column_tag_ids:         [layout.MAX_COLUMNS]layout.Column_ID,
	active_text_kind:       Text_Kind,
	active_column:          layout.Column_ID,
	typing_group:           u64,
	next_group:             u64,
	next_clipboard_request: u64,
	mouse_gesture:          mouse.State,
	scrollbar:              scroll.State,
	mouse_argument:         command.Argument,
	mouse_chord:            Mouse_Chord_Runtime,
	mouse_expanded:         bool,
	mouse_revision:         u64,
	mouse_generation:       u64,
	edit_runner:            edit.Runner,
	edit_window:            layout.Window_ID,
	edit_request:           edit.Request_ID,
	next_edit_request:      u64,
	workspace:              layout.Workspace,
	active_window:          layout.Window_ID,
	close_guard:            lifecycle.Close_Guard,
}

editor: Editor

editor_buffer_by_id :: proc(id: view.Buffer_ID) -> ^Editor_Buffer {
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id == id {
			return buffer
		}
	}
	return nil
}

editor_buffer_for_view :: proc(item: ^view.View) -> ^Editor_Buffer {
	if item == nil {
		return nil
	}
	return editor_buffer_by_id(item.buffer_id)
}

editor_destroy_buffer :: proc(buffer: ^Editor_Buffer) {
	if buffer == nil || buffer.id == 0 {
		return
	}
	txn.doc_destroy(&buffer.doc)
	delete(buffer.path, permanent())
	buffer^ = {}
	editor.buffer_count -= 1
}

editor_buffer_init :: proc(buffer: ^Editor_Buffer, id: view.Buffer_ID, path: string) -> errs.Error {
	buffer^ = {id = id, generation = DEFAULT_BUFFER_GENERATION}
	if path == "" {
		if err := txn.doc_init(&buffer.doc, {}, permanent()); !errs.ok(err) {
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
		if err := txn.doc_init_from_bytes(&buffer.doc, content, {}, permanent()); !errs.ok(err) {
			return err
		}
		buffer.capture = loaded.capture
		buffer.metadata = decoded.metadata
		log.infof("file: opened %s (%d bytes)", path, decoded.content.length)
	}
	buffer.path = strings.clone(path, permanent())
	return {}
}

editor_alloc_buffer :: proc(path: string) -> (^Editor_Buffer, errs.Error) {
	if editor.next_buffer_id == 0 {
		return nil, errs.new(.Resource_Limit, "file: buffer ID space exhausted", allocator = permanent())
	}
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id != 0 {
			continue
		}
		id := view.Buffer_ID(editor.next_buffer_id)
		if err := editor_buffer_init(buffer, id, path); !errs.ok(err) {
			buffer^ = {}
			return nil, err
		}
		editor.next_buffer_id += 1
		editor.buffer_count += 1
		return buffer, {}
	}
	return nil, errs.new(.Resource_Limit, "file: no buffer slot is available", allocator = permanent())
}

editor_alloc_buffer_content :: proc(path: string, content: []byte, kind: Buffer_Kind) -> (^Editor_Buffer, errs.Error) {
	if editor.next_buffer_id == 0 {
		return nil, errs.new(.Resource_Limit, "file: buffer ID space exhausted", allocator = permanent())
	}
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id != 0 {
			continue
		}
		buffer^ = {id = view.Buffer_ID(editor.next_buffer_id), generation = DEFAULT_BUFFER_GENERATION, kind = kind}
		if err := txn.doc_init_from_bytes(&buffer.doc, content, {}, permanent()); !errs.ok(err) {
			buffer^ = {}
			return nil, err
		}
		buffer.path = strings.clone(path, permanent())
		editor.next_buffer_id += 1
		editor.buffer_count += 1
		return buffer, {}
	}
	return nil, errs.new(.Resource_Limit, "file: no buffer slot is available", allocator = permanent())
}

editor_alloc_path_buffer :: proc(path: string) -> (^Editor_Buffer, errs.Error) {
	if path == "" {
		return editor_alloc_buffer(path)
	}
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil {
		kind := errs.Kind.IO
		if stat_err == .Not_Exist {
			kind = .NotFound
		}
		return nil, errs.newf(kind, "file: cannot stat %s: %v", path, stat_err, allocator = permanent())
	}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Directory {
		return editor_alloc_buffer(path)
	}
	content, read_err := directory.read(path, {}, context.temp_allocator)
	if !errs.ok(read_err) {
		owned := errs.new(read_err.kind, read_err.message, allocator = permanent())
		errs.destroy(&read_err)
		return nil, owned
	}
	defer delete(content, context.temp_allocator)
	listing_path := path
	owned_path := ""
	if !strings.has_suffix(listing_path, os.Path_Separator_String) {
		owned_path = strings.concatenate({listing_path, os.Path_Separator_String}, context.temp_allocator)
		listing_path = owned_path
	}
	defer if owned_path != "" {
		delete(owned_path, context.temp_allocator)
	}
	buffer, alloc_err := editor_alloc_buffer_content(listing_path, content, .Directory)
	if errs.ok(alloc_err) {
		log.infof("directory: opened %s buffer=%d bytes=%d", listing_path, u64(buffer.id), len(content))
	}
	return buffer, alloc_err
}

editor_init :: proc(path := "") -> errs.Error {
	editor.next_buffer_id = 1
	buffer, err := editor_alloc_path_buffer(path)
	if !errs.ok(err) {
		return err
	}
	editor.buffer = buffer
	if close_err := lifecycle.close_guard_init(&editor.close_guard, {}, permanent()); !errs.ok(close_err) {
		return close_err
	}
	return editor_workspace_init()
}

editor_workspace_init :: proc() -> errs.Error {
	if err := layout.workspace_init(&editor.workspace); !errs.ok(err) {
		return err
	}
	right, err := layout.add_column(&editor.workspace)
	if !errs.ok(err) {
		return err
	}
	if _, add_err := layout.add_window(&editor.workspace, right); !errs.ok(add_err) {
		return add_err
	}
	working_directory, directory_err := os.get_working_directory(context.temp_allocator)
	if directory_err != nil {
		return errs.newf(.IO, "directory: cannot resolve the working directory: %v", directory_err, allocator = permanent())
	}
	explorer, explorer_err := editor_alloc_path_buffer(working_directory)
	delete(working_directory, context.temp_allocator)
	if !errs.ok(explorer_err) {
		return explorer_err
	}
	first := true
	for column_index in 0 ..< editor.workspace.column_count {
		column := &editor.workspace.columns[column_index]
		for placed in column.windows[:column.window_count] {
			buffer := editor.buffer
			if !first {
				buffer = explorer
			}
			first = false
			if add_err := view.add(&editor.views, placed.id, buffer.id); !errs.ok(add_err) {
				return add_err
			}
			item, _ := view.find(&editor.views, placed.id)
			item.wrap_mode = cfg.Wrap_Mode
			if tag_err := editor_init_window_tag(item); !errs.ok(tag_err) {
				return tag_err
			}
		}
	}
	if tag_err := editor_init_global_and_column_tags(); !errs.ok(tag_err) {
		return tag_err
	}
	editor.active_window = editor.workspace.columns[0].windows[0].id
	editor.active_text_kind = .Body
	return {}
}

editor_destroy :: proc() {
	edit.runner_destroy(&editor.edit_runner)
	editor_cancel_pointer_gesture()
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		editor_cancel_delayed_paste(&item.delayed_paste)
		editor_cancel_delayed_cut(&item.delayed_cut)
		editor_cancel_tag_requests(&item.tag)
		tagstate.destroy(&item.tag)
	}
	editor_cancel_tag_requests(&editor.global_tag)
	tagstate.destroy(&editor.global_tag)
	for column_index in 0 ..< layout.MAX_COLUMNS {
		if editor.column_tag_ids[column_index] != 0 {
			editor_destroy_column_tag(editor.column_tag_ids[column_index])
		}
	}
	lifecycle.close_guard_destroy(&editor.close_guard)
	for index in 0 ..< view.MAX_VIEWS {
		editor_destroy_buffer(&editor.buffers[index])
	}
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
	case input.Scroll:
		if e.modifiers != {.Ctrl} {
			editor_scroll(e)
			return
		}
	case input.Key_Down, input.Key_Up:
		if editor_modifier_chord(event) {
			return
		}
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
		editor_indent_active(.Indent)
	case keybind.Outdent:
		editor.typing_group = 0
		editor_indent_active(.Outdent)
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
		selection, err := txn.doc_undo(editor_active_doc())
		if errs.ok(err) {
			editor_active_selection()^ = selection
			if editor.active_text_kind == .Body {
				editor_finish_history_jump(editor_active_view())
			}
		} else {
			if err.kind != .NotFound {
				log.warnf("edit: %v", errs.describe(err))
			}
			errs.destroy(&err)
		}
	case keybind.Redo:
		editor.typing_group = 0
		selection, err := txn.doc_redo(editor_active_doc())
		if errs.ok(err) {
			editor_active_selection()^ = selection
			if editor.active_text_kind == .Body {
				editor_finish_history_jump(editor_active_view())
			}
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
	case keybind.Execute_Text:
		editor.typing_group = 0
		target := editor_active_text_target()
		if target.selection != nil {
			offset := target.selection.active
			editor_execute_mouse(mouse.Execute{target = target.id, anchor = offset, active = offset})
		}
	case keybind.Look_Text:
		editor.typing_group = 0
		target := editor_active_text_target()
		if target.selection != nil {
			offset := target.selection.active
			editor_look_mouse(mouse.Look{target = target.id, anchor = offset, active = offset})
		}
	case keybind.Find, keybind.Open_Finder:
		log.debugf("edit: action %T is not connected in this milestone", action)
	case keybind.Request_Quit, keybind.Close_Window:
	}
}

editor_copy_selection :: proc() {
	editor_copy_target(editor_active_text_target())
}

editor_cut_selection :: proc() {
	editor_cut_target(editor_active_text_target())
}

editor_start_clipboard_write :: proc(
	doc: ^txn.Doc,
	range: rope.Byte_Range,
	request_id: platform.Clipboard_Request_ID,
) -> errs.Error {
	if doc == nil {
		return errs.new(.Invalid_Input, "clipboard: no source document")
	}
	if range.end - range.start > platform.DEFAULT_MAX_CLIPBOARD_BYTES {
		return errs.new(.Resource_Limit, "clipboard: selection exceeds the transfer budget")
	}
	data, err := rope.tree_read_all(&doc.tree, range, context.temp_allocator)
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
	editor_paste_target(editor_active_text_target())
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
	editor_poll_view_clipboards(&result)
	if !errs.ok(result.err) {
		err := result.err
		result.err = {}
		if err.kind == .NotFound {
			// A read with no selection owner (empty CLIPBOARD/PRIMARY) is a
			// normal no-op for a paste, not a user-facing error. Drop it
			// without logging a warning or opening an error window.
			log.infof("clipboard: no selection owner; paste is a no-op")
			errs.destroy(&err)
		} else {
			editor_report(err)
		}
	}
}

editor_cancel_delayed_paste :: proc(paste: ^editing.Delayed_Paste) {
	if paste == nil || !paste.pending {
		return
	}
	request_id := platform.Clipboard_Request_ID(paste.target.request_id)
	if services.clipboard.cancel != nil {
		services.clipboard.cancel(services.user, request_id)
	}
	editor_report(editing.delayed_paste_cancel(paste, u64(request_id)))
}

editor_cancel_delayed_cut :: proc(cut: ^editing.Delayed_Cut) {
	if cut == nil || !cut.pending {
		return
	}
	request_id := cut.target.request_id
	editor_report(editing.delayed_cut_cancel(cut, request_id))
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

editor_perform :: proc(action: editing.Action) {
	if editor.active_text_kind != .Body {
		#partial switch a in action {
		case editing.Insert_Text:
			if a.text == '\n' || a.text == '\r' {
				log.warn("tag: newline input is not allowed")
				return
			}
		case editing.Commit_Text:
			for r in a.text {
				if r == '\n' || r == '\r' {
					log.warn("tag: newline input is not allowed")
					return
				}
			}
		case:
		}
	}
	doc := editor_active_doc()
	previous_revision := txn.doc_revision(doc)
	err := editing.perform_with_options(
		doc,
		editor_active_selection(),
		action,
		{autopair = cfg.Autopair, auto_indent = true, indent = {style = .Tabs}},
	)
	if editor.active_text_kind == .Body {
		editor_finish_edit(editor_active_view(), previous_revision, err)
	} else {
		editor_report(err)
	}
}

editor_indent_active :: proc(direction: editing.Indent_Direction) {
	doc := editor_active_doc()
	previous_revision := txn.doc_revision(doc)
	err := editing.indent(doc, editor_active_selection(), direction, {style = .Tabs})
	if editor.active_text_kind == .Body {
		editor_finish_edit(editor_active_view(), previous_revision, err)
	} else {
		editor_report(err)
	}
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

editor_save_buffer :: proc(buffer: ^Editor_Buffer) -> errs.Error {
	if buffer == nil {
		return errs.new(.Invalid_Input, "save: no buffer", allocator = context.temp_allocator)
	}
	if buffer.kind != .File {
		return errs.new(.Unsupported, "save: directory and error windows cannot be saved as files", allocator = context.temp_allocator)
	}
	if buffer.path == "" {
		return errs.new(
			.Unsupported,
			"save: no file path; Save As requires a destination from tag commands",
			allocator = context.temp_allocator,
		)
	}
	revision := txn.doc_revision(&buffer.doc)
	if revision == buffer.saved_revision {
		log.debugf("file: %s is already saved", buffer.path)
		return {}
	}

	result, err := filesave.save_tree(
		{tree = &buffer.doc.tree, root = buffer.doc.tree.root, revision = revision},
		buffer.path,
		buffer.metadata,
		{disk_check = .Unchanged, expected = buffer.capture},
		context.temp_allocator,
	)
	if !errs.ok(err) {
		if result.replaced {
			log.error("file: save published the destination but did not complete; buffer remains dirty and must not be blindly retried")
		}
		return err
	}
	if result.revision != txn.doc_revision(&buffer.doc) {
		return errs.new(
			.Conflict,
			"file: saved revision no longer matches the current buffer",
			allocator = context.temp_allocator,
		)
	}
	buffer.saved_revision = result.revision
	buffer.capture = result.capture
	editor_refresh_window_tags()
	log.infof("file: saved %s (revision %d)", buffer.path, result.revision)
	return {}
}

editor_save :: proc() {
	editor_report(editor_save_buffer(editor.buffer))
}

editor_putall :: proc() {
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id == 0 || buffer.kind != .File || buffer.path == "" ||
			txn.doc_revision(&buffer.doc) == buffer.saved_revision {
			continue
		}
		info, stat_err := os.stat(buffer.path, context.temp_allocator)
		if stat_err != nil {
			log.warnf("file: no automatic Put of %s: %v", buffer.path, stat_err)
			continue
		}
		regular := info.type == .Regular
		os.file_info_delete(info, context.temp_allocator)
		if !regular {
			continue
		}
		editor_report(editor_save_buffer(buffer))
	}
}

editor_reload_buffer :: proc(item: ^view.View, path: string) -> errs.Error {
	if item == nil || path == "" {
		return errs.new(.Invalid_Input, "get: no window or file name", allocator = permanent())
	}
	buffer := editor_buffer_for_view(item)
	if buffer == nil {
		return errs.new(.Internal, "get: window has no buffer", allocator = permanent())
	}
	if buffer.kind == .Errors {
		return errs.new(.Unsupported, "get: error windows cannot be reloaded", allocator = permanent())
	}

	editor_cancel_close_review()
	snapshot := lifecycle.Buffer_Snapshot{
		id = u64(buffer.id),
		generation = buffer.generation,
		revision = txn.doc_revision(&buffer.doc),
		view_count = view.buffer_view_count(&editor.views, buffer.id),
		dirty = txn.doc_revision(&buffer.doc) != buffer.saved_revision,
	}
	request := lifecycle.Close_Request{
		kind = .Close_Buffer,
		origin = .Tag_Command,
		buffer_id = snapshot.id,
		buffer_generation = snapshot.generation,
	}
	if err := lifecycle.close_request(&editor.close_guard, request, []lifecycle.Buffer_Snapshot{snapshot}); !errs.ok(err) {
		return err
	}
	if !lifecycle.close_guard_ready(&editor.close_guard) {
		log.warnf("get: %s has unsaved text; reload blocked", buffer.path)
		return {}
	}
	lifecycle.close_guard_reset(&editor.close_guard)

	loaded: Editor_Buffer
	if buffer.kind == .File {
		if err := editor_buffer_init(&loaded, 0, path); !errs.ok(err) {
			return err
		}
	} else {
		content, err := directory.read(path, {}, context.temp_allocator)
		if !errs.ok(err) {
			owned := errs.new(err.kind, err.message, allocator = permanent())
			errs.destroy(&err)
			return owned
		}
		defer delete(content, context.temp_allocator)
		if init_err := txn.doc_init_from_bytes(&loaded.doc, content, {}, permanent()); !errs.ok(init_err) {
			return init_err
		}
	}
	defer txn.doc_destroy(&loaded.doc)
	defer delete(loaded.path, permanent())

	content, read_err := rope.tree_read_all(&loaded.doc.tree, {0, rope.tree_byte_count(&loaded.doc.tree)}, context.temp_allocator)
	if !errs.ok(read_err) {
		owned := errs.new(read_err.kind, read_err.message, allocator = permanent())
		errs.destroy(&read_err)
		return owned
	}
	defer delete(content, context.temp_allocator)
	new_total := len(content)
	after := txn.Selection{
		anchor = min(item.selection.anchor, new_total),
		active = min(item.selection.active, new_total),
		affinity = item.selection.affinity,
	}
	transaction := txn.Transaction{
		source = .Reload,
		base_revision = txn.doc_revision(&buffer.doc),
		ops = []txn.Operation{txn.Replace{range = {0, rope.tree_byte_count(&buffer.doc.tree)}, data = content}},
		after_selection = after,
	}
	if err := txn.doc_apply(&buffer.doc, &transaction, permanent()); !errs.ok(err) {
		return err
	}
	item.selection = after
	view.transform_after_edit(&editor.views, item.window_id, buffer.id, transaction.ops, new_total)
	for index in 0 ..< view.MAX_VIEWS {
		other := &editor.views.views[index]
		if other.window_id != 0 && other.buffer_id == buffer.id {
			other.first_line = 0
			other.first_row = 0
			other.wheel_remainder = 0
			other.horizontal_offset = 0
		}
	}
	buffer.regex_history = {}
	if path == buffer.path {
		buffer.capture = loaded.capture
		buffer.metadata = loaded.metadata
		buffer.saved_revision = txn.doc_revision(&buffer.doc)
	}
	editor_refresh_window_tags()
	log.infof("file: reloaded %s window=%d buffer=%d revision=%d", path, u64(item.window_id), u64(buffer.id), txn.doc_revision(&buffer.doc))
	return {}
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
	snapshots: [view.MAX_VIEWS]lifecycle.Buffer_Snapshot
	snapshot_count := 0
	if kind == .Quit {
		for index in 0 ..< view.MAX_VIEWS {
			buffer := &editor.buffers[index]
			if buffer.id == 0 {
				continue
			}
			snapshots[snapshot_count] = {
				id = u64(buffer.id),
				generation = buffer.generation,
				revision = txn.doc_revision(&buffer.doc),
				view_count = view.buffer_view_count(&editor.views, buffer.id),
				dirty = txn.doc_revision(&buffer.doc) != buffer.saved_revision,
			}
			snapshot_count += 1
		}
	} else {
		snapshots[0] = {
			id = u64(editor.buffer.id),
			generation = editor.buffer.generation,
			revision = txn.doc_revision(&editor.buffer.doc),
			view_count = view.buffer_view_count(&editor.views, editor.buffer.id),
			dirty = editor_dirty(),
		}
		snapshot_count = 1
	}
	if err := lifecycle.close_request(&editor.close_guard, request, snapshots[:snapshot_count]); !errs.ok(err) {
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
	buffer_id := item.buffer_id
	editor_cancel_delayed_paste(&item.delayed_paste)
	editor_cancel_delayed_cut(&item.delayed_cut)
	editor_cancel_tag_requests(&item.tag)
	tagstate.destroy(&item.tag)
	view.remove(&editor.views, window_id)
	layout.remove_window(&editor.workspace, window_id)
	if view.buffer_view_count(&editor.views, buffer_id) == 0 {
		editor_destroy_buffer(editor_buffer_by_id(buffer_id))
	}
	next := editor_active_view()
	if next == nil {
		if first := editor_first_view(); first != nil {
			editor_activate_window(first.window_id)
		}
	}
	editor_cancel_pointer_gesture()
	lifecycle.close_guard_reset(&editor.close_guard)
	log.infof("view: closed window %d; %d views remain", u64(window_id), editor.views.view_count)
}

editor_request_close_column :: proc(column_id: layout.Column_ID) -> errs.Error {
	column_index, found := layout.find_column(&editor.workspace, column_id)
	if !found {
		return errs.new(.NotFound, "view: cannot delete a missing column", allocator = permanent())
	}
	editor_cancel_close_review()
	snapshots: [view.MAX_VIEWS]lifecycle.Buffer_Snapshot
	snapshot_count := 0
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		item_column, _, item_found := layout.find_window(&editor.workspace, item.window_id)
		if !item_found || item_column != column_index {
			continue
		}
		buffer := editor_buffer_for_view(item)
		if buffer == nil {
			return errs.new(.Internal, "view: column window has no buffer", allocator = permanent())
		}
		duplicate := false
		for previous in snapshots[:snapshot_count] {
			if previous.id == u64(buffer.id) {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		snapshots[snapshot_count] = {
			id = u64(buffer.id),
			generation = buffer.generation,
			revision = txn.doc_revision(&buffer.doc),
			view_count = view.buffer_view_count(&editor.views, buffer.id),
			dirty = txn.doc_revision(&buffer.doc) != buffer.saved_revision,
		}
		snapshot_count += 1
	}
	request := lifecycle.Close_Request{kind = .Close_Column, origin = .Tag_Command}
	if err := lifecycle.close_request(&editor.close_guard, request, snapshots[:snapshot_count]); !errs.ok(err) {
		return err
	}
	if !lifecycle.close_guard_ready(&editor.close_guard) {
		log.warn("view: column has unsaved text; deletion blocked until it is saved or explicitly discarded")
		return {}
	}

	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id == 0 {
			continue
		}
		item_column, _, item_found := layout.find_window(&editor.workspace, item.window_id)
		if !item_found || item_column != column_index {
			continue
		}
		buffer_id := item.buffer_id
		editor_cancel_delayed_paste(&item.delayed_paste)
		editor_cancel_delayed_cut(&item.delayed_cut)
		editor_cancel_tag_requests(&item.tag)
		tagstate.destroy(&item.tag)
		view.remove(&editor.views, item.window_id)
		if view.buffer_view_count(&editor.views, buffer_id) == 0 {
			editor_destroy_buffer(editor_buffer_by_id(buffer_id))
		}
	}
	editor_destroy_column_tag(column_id)
	layout.remove_column(&editor.workspace, column_id)
	lifecycle.close_guard_reset(&editor.close_guard)
	editor_cancel_pointer_gesture()
	editor.active_column = 0
	editor.active_text_kind = .Body
	if editor.active_window != 0 {
		if _, _, active_found := layout.find_window(&editor.workspace, editor.active_window); !active_found {
			editor.active_window = 0
			editor.buffer = nil
		}
	}
	if first := editor_first_view(); first != nil {
		editor_activate_window(first.window_id)
	}
	log.infof("view: deleted column %d; %d columns and %d views remain", u64(column_id), editor.workspace.column_count, editor.views.view_count)
	if editor.views.view_count == 0 {
		request_quit(.User_Request, "editor-close-last-column")
	}
	return {}
}

MAX_ERROR_WINDOW_BYTES :: 256 * 1024

editor_error_buffer :: proc() -> ^Editor_Buffer {
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id != 0 && buffer.kind == .Errors {
			return buffer
		}
	}
	return nil
}

editor_append_error :: proc(message: string) -> errs.Error {
	line := fmt.aprintf("%s\n", message, allocator = context.temp_allocator)
	defer delete(line, context.temp_allocator)
	if len(line) > MAX_ERROR_WINDOW_BYTES {
		return errs.newf(.Resource_Limit, "errors: message exceeds the %d-byte window limit", MAX_ERROR_WINDOW_BYTES, allocator = context.temp_allocator)
	}
	if buffer := editor_error_buffer(); buffer != nil {
		item := editor_first_view_for_buffer(buffer.id)
		if item == nil {
			return errs.new(.Internal, "errors: buffer has no view", allocator = context.temp_allocator)
		}
		start := rope.tree_byte_count(&buffer.doc.tree)
		if len(line) > MAX_ERROR_WINDOW_BYTES - start {
			return errs.newf(.Resource_Limit, "errors: window exceeds the %d-byte limit", MAX_ERROR_WINDOW_BYTES, allocator = context.temp_allocator)
		}
		was_dirty := txn.doc_revision(&buffer.doc) != buffer.saved_revision
		end := start + len(line)
		selection := txn.Selection{anchor = end, active = end, affinity = .Left}
		ops := []txn.Operation{txn.Insert{pos = start, data = transmute([]byte)line}}
		transaction := txn.Transaction {
			source = .Command_Output,
			base_revision = txn.doc_revision(&buffer.doc),
			ops = ops,
			after_selection = selection,
		}
		if apply_err := txn.doc_apply(&buffer.doc, &transaction, permanent()); !errs.ok(apply_err) {
			return apply_err
		}
		view.transform_after_edit(&editor.views, item.window_id, buffer.id, transaction.ops, end)
		item.selection = selection
		if !was_dirty {
			buffer.saved_revision = txn.doc_revision(&buffer.doc)
		}
		log.infof("errors: appended window=%d buffer=%d bytes=%d", u64(item.window_id), u64(buffer.id), end)
		return {}
	}
	if editor.workspace.column_count == 0 {
		return errs.new(.NotFound, "errors: no column is available", allocator = context.temp_allocator)
	}
	buffer, alloc_err := editor_alloc_buffer_content("", transmute([]byte)line, .Errors)
	if !errs.ok(alloc_err) {
		return alloc_err
	}
	column_id := editor.workspace.columns[editor.workspace.column_count - 1].id
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		return open_err
	}
	log.infof("errors: opened window=%d buffer=%d bytes=%d", u64(item.window_id), u64(buffer.id), len(line))
	return {}
}

editor_report :: proc(err: errs.Error) {
	if errs.ok(err) {
		return
	}
	log.warnf("edit: %v", errs.describe(err))
	if display_err := editor_append_error(err.message); !errs.ok(display_err) {
		log.warnf("errors: cannot display error: %v", errs.describe(display_err))
		errs.destroy(&display_err)
	}
	owned := err
	errs.destroy(&owned)
}
