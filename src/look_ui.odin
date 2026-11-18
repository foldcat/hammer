package main

import "core:log"
import "core:os"

import errs "core/errs"
import layout "core/layout"
import mouse "core/mouse"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

Look_Open_Result :: enum u8 {
	Not_A_File,
	Opened,
	Failed,
}

editor_clean_look_path :: proc(candidate, original: string, allocator := context.temp_allocator) -> (string, errs.Error) {
	if os.is_absolute_path(candidate) {
		cleaned, clean_err := os.clean_path(candidate, allocator)
		if clean_err != .None {
			return "", errs.newf(.Resource_Limit, "look: cannot normalize %q: %v", original, clean_err, allocator = allocator)
		}
		return cleaned, {}
	}
	working_directory, directory_err := os.get_working_directory(allocator)
	if directory_err != nil {
		return "", errs.newf(.IO, "look: cannot resolve the working directory: %v", directory_err, allocator = allocator)
	}
	joined, join_err := os.join_path([]string{working_directory, candidate}, allocator)
	delete(working_directory, allocator)
	if join_err != .None {
		return "", errs.newf(.Resource_Limit, "look: cannot resolve %q: %v", original, join_err, allocator = allocator)
	}
	cleaned, clean_err := os.clean_path(joined, allocator)
	delete(joined, allocator)
	if clean_err != .None {
		return "", errs.newf(.Resource_Limit, "look: cannot normalize %q: %v", original, clean_err, allocator = allocator)
	}
	return cleaned, {}
}

editor_normalized_look_path :: proc(path: string, source: Mouse_Text_Target, allocator := context.temp_allocator) -> (string, errs.Error) {
	if os.is_absolute_path(path) {
		return editor_clean_look_path(path, path, allocator)
	}
	base := "."
	if source.item != nil {
		buffer := editor_buffer_for_view(source.item)
		if buffer != nil && buffer.path != "" {
			base = os.dir(buffer.path)
			if buffer.kind == .Directory {
				base = buffer.path
			}
		}
	}
	joined, join_err := os.join_path([]string{base, path}, allocator)
	if join_err != .None {
		return "", errs.newf(.Resource_Limit, "look: cannot resolve %q: %v", path, join_err, allocator = allocator)
	}
	cleaned, err := editor_clean_look_path(joined, path, allocator)
	delete(joined, allocator)
	return cleaned, err
}

editor_find_open_buffer_path :: proc(path: string, allocator := context.temp_allocator) -> ^Editor_Buffer {
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id == 0 || buffer.path == "" {
			continue
		}
		candidate, err := editor_normalized_look_path(buffer.path, {}, allocator)
		if !errs.ok(err) {
			errs.destroy(&err)
			continue
		}
		if os.are_paths_identical(candidate, path) {
			delete(candidate, allocator)
			return buffer
		}
		delete(candidate, allocator)
	}
	return nil
}

editor_first_view_for_buffer :: proc(id: view.Buffer_ID) -> ^view.View {
	for index in 0 ..< view.MAX_VIEWS {
		item := &editor.views.views[index]
		if item.window_id != 0 && item.buffer_id == id {
			return item
		}
	}
	return nil
}

editor_look_column :: proc(target: Mouse_Text_Target) -> layout.Column_ID {
	if target.column_id != 0 {
		if _, ok := layout.find_column(&editor.workspace, target.column_id); ok {
			return target.column_id
		}
	}
	if target.window_id != 0 {
		if column, _, ok := layout.find_window(&editor.workspace, target.window_id); ok {
			return editor.workspace.columns[column].id
		}
	}
	if editor.active_column != 0 {
		if _, ok := layout.find_column(&editor.workspace, editor.active_column); ok {
			return editor.active_column
		}
	}
	if editor.active_window != 0 {
		if column, _, ok := layout.find_window(&editor.workspace, editor.active_window); ok {
			return editor.workspace.columns[column].id
		}
	}
	if editor.workspace.column_count > 0 {
		return editor.workspace.columns[0].id
	}
	return 0
}

editor_apply_look_line :: proc(item: ^view.View, line: int) {
	if item == nil || line <= 0 {
		return
	}
	buffer := editor_buffer_for_view(item)
	if buffer == nil {
		return
	}
	line_index := rope.Line_Index(line - 1)
	start, err := rope.tree_line_start(&buffer.doc.tree, line_index, context.temp_allocator)
	if !errs.ok(err) {
		editor_report(err)
		return
	}
	item.selection = txn.Selection{anchor = start, active = start, affinity = .Left}
	item.first_line = line_index
	item.first_row = 0
	item.wheel_remainder = 0
}

editor_open_buffer_in_column :: proc(buffer: ^Editor_Buffer, column_id: layout.Column_ID) -> (^view.View, errs.Error) {
	if buffer == nil {
		return nil, errs.new(.Invalid_Input, "view: cannot open a nil buffer", allocator = permanent())
	}
	if column_id == 0 {
		editor_destroy_buffer(buffer)
		return nil, errs.new(.NotFound, "view: no column is available", allocator = permanent())
	}
	window_id, layout_err := layout.add_window(&editor.workspace, column_id)
	if !errs.ok(layout_err) {
		editor_destroy_buffer(buffer)
		return nil, layout_err
	}
	if add_err := view.add(&editor.views, window_id, buffer.id); !errs.ok(add_err) {
		layout.remove_window(&editor.workspace, window_id)
		editor_destroy_buffer(buffer)
		return nil, add_err
	}
	item, _ := view.find(&editor.views, window_id)
	item.wrap_mode = cfg.Wrap_Mode
	if tag_err := editor_init_window_tag(item); !errs.ok(tag_err) {
		view.remove(&editor.views, window_id)
		layout.remove_window(&editor.workspace, window_id)
		editor_destroy_buffer(buffer)
		return nil, tag_err
	}
	return item, {}
}

editor_open_look_file :: proc(target: Mouse_Text_Target, text: string) -> Look_Open_Result {
	reference := mouse.parse_look_path(text)
	if reference.path == "" {
		return .Not_A_File
	}
	for r in reference.path {
		if r < 0x20 || r == 0x7f {
			return .Not_A_File
		}
	}
	path, path_err := editor_normalized_look_path(reference.path, target, context.temp_allocator)
	if !errs.ok(path_err) {
		editor_report(path_err)
		return .Failed
	}
	defer delete(path, context.temp_allocator)

	if buffer := editor_find_open_buffer_path(path, context.temp_allocator); buffer != nil {
		item := editor_first_view_for_buffer(buffer.id)
		if item == nil {
			editor_report(errs.new(.Internal, "look: open buffer has no view", allocator = context.temp_allocator))
			return .Failed
		}
		editor_activate_window(item.window_id)
		editor_apply_look_line(item, reference.line)
		log.infof("look: activated %s window=%d buffer=%d line=%d", path, u64(item.window_id), u64(buffer.id), reference.line)
		return .Opened
	}

	buffer, load_err := editor_alloc_path_buffer(path)
	if !errs.ok(load_err) {
		if load_err.kind == .NotFound {
			errs.destroy(&load_err)
			return .Not_A_File
		}
		editor_report(load_err)
		return .Failed
	}
	item, open_err := editor_open_buffer_in_column(buffer, editor_look_column(target))
	if !errs.ok(open_err) {
		editor_report(open_err)
		return .Failed
	}
	editor_activate_window(item.window_id)
	editor_apply_look_line(item, reference.line)
	log.infof("look: opened %s window=%d buffer=%d line=%d", path, u64(item.window_id), u64(buffer.id), reference.line)
	return .Opened
}

editor_look_text :: proc(target: Mouse_Text_Target, needle: []byte, reverse: bool) {
	log.debugf("look: resolving %q", string(needle))
	if editor_open_look_file(target, string(needle)) != .Not_A_File {
		return
	}
	editor_search_body(editor_target_body(target), needle, reverse)
}
