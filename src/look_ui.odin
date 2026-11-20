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

editor_file_basename :: proc(path: string) -> string {
	base := path
	for r, index in path {
		if r == '/' || r == '\\' {
			base = path[index + 1:]
		}
	}
	return base
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
	if editor.active_window != 0 {
		if column, _, ok := layout.find_window(&editor.workspace, editor.active_window); ok {
			return editor.workspace.columns[column].id
		}
	}
	if editor.active_column != 0 {
		if _, ok := layout.find_column(&editor.workspace, editor.active_column); ok {
			return editor.active_column
		}
	}
	if editor.workspace.column_count > 0 {
		return editor.workspace.columns[0].id
	}
	return 0
}

editor_apply_look_position :: proc(item: ^view.View, line, col: int) {
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
	line_end, end_err := editor_line_content_end(buffer, line_index)
	if !errs.ok(end_err) {
		editor_report(end_err)
		return
	}
	item.first_line = line_index
	item.first_row = 0
	item.wheel_remainder = 0
	if col > 0 {
		// A column address places a precise caret; a column past the line
		// end clamps to the line's last character rather than discarding
		// the jump, matching Acme's column walk that never leaves the line.
		position := line_end
		if byte_pos, col_err := rope.tree_line_col_to_byte(&buffer.doc.tree, line_index, rope.Column_Index(col - 1), context.temp_allocator); errs.ok(col_err) {
			position = byte_pos
		}
		item.selection = txn.Selection{anchor = position, active = position, affinity = .Left}
		editor_reveal_caret(item)
	} else {
		// A line address selects the whole line, matching Acme, so the jump
		// destination is visible. The caret lands at the line start.
		item.selection = txn.Selection{anchor = line_end, active = start, affinity = .Left}
		item.horizontal_offset = 0
	}
}

// editor_line_content_end returns the byte offset just past the last visible
// character of `line` (the trailing line break is excluded), matching the
// line-selection convention used elsewhere in the editor.
editor_line_content_end :: proc(buffer: ^Editor_Buffer, line: rope.Line_Index) -> (int, errs.Error) {
	start, start_err := rope.tree_line_start(&buffer.doc.tree, line, context.temp_allocator)
	if !errs.ok(start_err) {
		return 0, start_err
	}
	end, end_err := rope.tree_line_end(&buffer.doc.tree, line, context.temp_allocator)
	if !errs.ok(end_err) {
		return 0, end_err
	}
	if end > start {
		tail_start := max(start, end - 2)
		tail: [2]u8
		n, read_err := rope.tree_read(&buffer.doc.tree, rope.Byte_Range{tail_start, end}, tail[:end - tail_start])
		if errs.ok(read_err) {
			if n > 0 && tail[n - 1] == '\n' {
				end -= 1
				if n > 1 && tail[n - 2] == '\r' {
					end -= 1
				}
			} else if n > 0 && tail[n - 1] == '\r' {
				end -= 1
			}
		}
	}
	return end, {}
}

// On failure, destroy_on_error controls ownership of buffer. Zerox passes false
// because its buffer remains owned by existing views.
editor_open_buffer_in_column :: proc(buffer: ^Editor_Buffer, column_id: layout.Column_ID, destroy_on_error := true) -> (^view.View, errs.Error) {
	if buffer == nil {
		return nil, errs.new(.Invalid_Input, "view: cannot open a nil buffer", allocator = permanent())
	}
	if column_id == 0 {
		if destroy_on_error {
			editor_destroy_buffer(buffer)
		}
		return nil, errs.new(.NotFound, "view: no column is available", allocator = permanent())
	}
	window_id, layout_err := layout.add_window(&editor.workspace, column_id)
	if !errs.ok(layout_err) {
		if destroy_on_error {
			editor_destroy_buffer(buffer)
		}
		return nil, layout_err
	}
	if add_err := view.add(&editor.views, window_id, buffer.id); !errs.ok(add_err) {
		layout.remove_window(&editor.workspace, window_id)
		if destroy_on_error {
			editor_destroy_buffer(buffer)
		}
		return nil, add_err
	}
	item, _ := view.find(&editor.views, window_id)
	item.wrap_mode = cfg.Wrap_Mode
	if tag_err := editor_init_window_tag(item); !errs.ok(tag_err) {
		view.remove(&editor.views, window_id)
		layout.remove_window(&editor.workspace, window_id)
		if destroy_on_error {
			editor_destroy_buffer(buffer)
		}
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

	result := editor_try_open_look(target, path, reference)
	if result != .Not_A_File {
		return result
	}

	// A bare basename that was not found in the source directory may live in
	// a subdirectory: compiler output (`reverb_http.adb:169:44`) often omits
	// the source directory. Search the source directory's subtree with tight
	// bounds before giving up and falling back to literal search.
	if os.dir(reference.path) == "" {
		root := os.dir(path)
		if root == "" {
			root = "."
		}
		if found_path, ok := editor_find_basename_under(root, reference.path); ok {
			result = editor_try_open_look(target, found_path, reference)
			if result != .Not_A_File {
				return result
			}
		}
	}
	return .Not_A_File
}

// editor_try_open_look activates an already-open buffer or loads and opens
// `path`, then applies the line/column jump. It returns .Not_A_File only when
// the path does not exist, so the caller can try an alternative path.
editor_try_open_look :: proc(target: Mouse_Text_Target, path: string, reference: mouse.Look_Path) -> Look_Open_Result {
	if buffer := editor_find_open_buffer_path(path, context.temp_allocator); buffer != nil {
		item := editor_first_view_for_buffer(buffer.id)
		if item == nil {
			editor_report(errs.new(.Internal, "look: open buffer has no view", allocator = context.temp_allocator))
			return .Failed
		}
		editor_activate_window(item.window_id)
		editor_apply_look_position(item, reference.line, reference.col)
		log.infof("look: activated %s window=%d buffer=%d line=%d col=%d", path, u64(item.window_id), u64(buffer.id), reference.line, reference.col)
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
	editor_apply_look_position(item, reference.line, reference.col)
	log.infof("look: opened %s window=%d buffer=%d line=%d col=%d", path, u64(item.window_id), u64(buffer.id), reference.line, reference.col)
	return .Opened
}

LOOK_SEARCH_MAX_DEPTH :: 16
LOOK_SEARCH_MAX_ENTRIES :: 4096

// Directories the fallback basename search never descends into: build outputs
// and dependency caches that can otherwise contain a same-named file that is
// not the user's source. Hidden entries (`.git`, caches, ...) are also skipped.
LOOK_SEARCH_SKIP_DIRS := [?]string{
	"obj", "bin", "target", "build", "out", "dist",
	"node_modules", "vendor", "alire", "deps",
}

editor_look_skip_dir :: proc(name: string) -> bool {
	if name == "" || name[0] == '.' {
		return true
	}
	for skip in LOOK_SEARCH_SKIP_DIRS {
		if name == skip {
			return true
		}
	}
	return false
}

// editor_find_basename_under searches `root` recursively for a file named
// exactly `name` and returns its absolute path. The walk is bounded in depth
// and entry count; the first match wins. The result lives on the frame scratch
// arena, valid until the end of the frame.
editor_find_basename_under :: proc(root, name: string) -> (string, bool) {
	remaining := LOOK_SEARCH_MAX_ENTRIES
	found_path := ""
	found := false
	editor_search_directory(root, name, 0, &remaining, &found_path, &found)
	return found_path, found
}

editor_search_directory :: proc(dir, name: string, depth: int, remaining: ^int, found_path: ^string, found: ^bool) {
	if found^ || depth > LOOK_SEARCH_MAX_DEPTH || remaining^ <= 0 {
		return
	}
	file, open_err := os.open(dir, {.Read})
	if open_err != nil {
		return
	}
	defer os.close(file)
	iterator := os.read_directory_iterator_create(file)
	defer os.read_directory_iterator_destroy(&iterator)
	for entry in os.read_directory_iterator(&iterator) {
		if found^ || remaining^ <= 0 {
			break
		}
		remaining^ -= 1
		if entry.name == "" {
			continue
		}
		if entry.type == .Directory {
			if editor_look_skip_dir(entry.name) {
				continue
			}
			sub, join_err := os.join_path([]string{dir, entry.name}, context.temp_allocator)
			if join_err == .None {
				editor_search_directory(sub, name, depth + 1, remaining, found_path, found)
			}
		} else if entry.type == .Regular && entry.name == name {
			joined, join_err := os.join_path([]string{dir, entry.name}, context.temp_allocator)
			if join_err == .None {
				if cleaned, clean_err := os.clean_path(joined, context.temp_allocator); clean_err == .None {
					found_path^ = cleaned
					found^ = true
				}
			}
			return
		}
	}
}

editor_look_text :: proc(target: Mouse_Text_Target, needle: []byte, reverse: bool) {
	log.debugf("look: resolving %q", string(needle))
	if editor_open_look_file(target, string(needle)) != .Not_A_File {
		return
	}
	editor_search_body(editor_target_body(target), needle, reverse)
}
