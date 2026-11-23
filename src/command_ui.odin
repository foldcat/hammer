package main

import "core:log"
import "core:strings"

import command "core/command"
import edit "core/edit"
import editing "core/editing"
import errs "core/errs"
import layout "core/layout"
import lifecycle "core/lifecycle"
import mouse "core/mouse"
import process "core/process"
import rope "core/rope"
import tagstate "core/tag"
import txn "core/txn"
import view "core/view"

EDITOR_COMMANDS :: []command.Entry {
	{name = "Apply", handler = editor_command_apply},
	{name = "Cmd", handler = editor_command_cmds},
	{name = "Cmds", handler = editor_command_cmds},
	{name = "Del", handler = editor_command_del},
	{name = "Delcol", handler = editor_command_delcol},
	{name = "Exit", handler = editor_command_exit},
	{name = "Get", handler = editor_command_get},
	{name = "New", handler = editor_command_new},
	{name = "Newcol", handler = editor_command_newcol},
	{name = "Put", handler = editor_command_put},
	{name = "Putall", handler = editor_command_putall},
	{name = "Raku", handler = editor_command_raku},
	{name = "RakuEval", handler = editor_command_raku_eval},
	{name = "RakuRepl", handler = editor_command_raku_repl},
	{name = "Zerox", handler = editor_command_zerox},
	{name = "Edit", handler = editor_command_edit},
	{name = "Undo", handler = editor_command_undo},
	{name = "Redo", handler = editor_command_redo},
	{name = "Cut", handler = editor_command_cut},
	{name = "Snarf", handler = editor_command_snarf},
	{name = "Wait", handler = editor_command_wait},
	{name = "Stop", handler = editor_command_stop},
	{name = "Jobs", handler = editor_command_jobs},
	{name = "Kill", handler = editor_command_kill},
	{name = "Paste", handler = editor_command_paste},
	{name = "Look", handler = editor_command_look},
	{name = "Win", handler = editor_command_win},
}

editor_capture_mouse_argument :: proc(target: Mouse_Text_Target) {
	if target.doc == nil || target.selection == nil {
		return
	}
	editor.mouse_argument = {
		valid = true,
		target_id = u64(target.id),
		selection = target.selection^,
		buffer_id = target.buffer_id,
		generation = target.generation,
		revision = txn.doc_revision(target.doc),
	}
}

editor_command_context :: proc(target: Mouse_Text_Target, command_range: rope.Byte_Range, with_argument: bool) -> command.Context {
	source := command.Source {
		kind = target.kind,
		target_id = u64(target.id),
		window_id = u64(target.window_id),
		column_id = u64(target.column_id),
		buffer_id = target.buffer_id,
		buffer_generation = target.generation,
		revision = txn.doc_revision(target.doc),
		selection = target.selection^,
		command_range = command_range,
	}
	if target.item != nil {
		if buffer := editor_buffer_for_view(target.item); buffer != nil {
			source.file_path = buffer.path
		}
	}
	return command.Context{
		source = source,
		argument = editor.mouse_argument,
		argument_chord = with_argument,
	}
}

editor_command_source_target :: proc(source: command.Source) -> Mouse_Text_Target {
	target := editor_text_target_by_id(mouse.Target_ID(source.target_id))
	if target.doc == nil || target.selection == nil || target.kind != source.kind ||
		u64(target.window_id) != source.window_id || u64(target.column_id) != source.column_id ||
		target.buffer_id != source.buffer_id || target.generation != source.buffer_generation ||
		txn.doc_revision(target.doc) != source.revision {
		return {}
	}
	return target
}

editor_command_argument_target :: proc(argument: ^command.Argument) -> (Mouse_Text_Target, bool) {
	if argument == nil || !argument.valid {
		return {}, false
	}
	target := editor_text_target_by_id(mouse.Target_ID(argument.target_id))
	if target.doc == nil || target.selection == nil || target.buffer_id != argument.buffer_id ||
		target.generation != argument.generation || txn.doc_revision(target.doc) != argument.revision {
		return {}, false
	}
	if !txn.selection_in_bounds(argument.selection, rope.tree_byte_count(&target.doc.tree)) {
		return {}, false
	}
	target.selection = &argument.selection
	return target, true
}

editor_execute_mouse :: proc(action: mouse.Execute) {
	target := editor_text_target_by_id(action.target)
	if target.doc == nil || target.selection == nil {
		return
	}
	range, range_err := mouse.action_range(target.doc, target.selection^, action.anchor, action.active, .Execute)
	if !errs.ok(range_err) {
		editor_report(range_err)
		return
	}
	data, read_err := mouse.read_action_text(target.doc, range, context.temp_allocator)
	if !errs.ok(read_err) {
		editor_report(read_err)
		return
	}
	defer delete(data, context.temp_allocator)
	command_text := strings.trim_space(string(data))
	if command_text == "" {
		return
	}

	if routing, pipe_text, is_pipe := command.pipe_parse(command_text); is_pipe {
		editor_execute_external(target, range, routing, pipe_text)
		return
	}

	invocation, parse_err := command.parse(command_text, context.temp_allocator)
	if !errs.ok(parse_err) {
		editor_report(parse_err)
		return
	}
	if invocation.name != "Wait" && invocation.name != "Stop" && invocation.name != "Exit" {
		editor_cancel_job_quit()
	}
	log.infof("mouse: execute %q target=%d argument_chord=%v", invocation.name, u64(action.target), action.with_argument)
	cmd_context := editor_command_context(target, range, action.with_argument)
	handled, dispatch_err := command.dispatch(EDITOR_COMMANDS, invocation, &cmd_context, context.temp_allocator)
	if !handled && dispatch_err.kind == .NotFound {
		errs.destroy(&dispatch_err)
		filter_handled, filter_err := editor_invoke_filter(&cmd_context, invocation)
		if !filter_handled {
			// Unknown command: run it directly in the shell.
			editor_execute_external(target, range, .Plain, command_text)
			return
		}
		editor_report(filter_err)
		return
	}
	editor_report(dispatch_err)
}

editor_command_apply :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "job: Apply takes no arguments", allocator = permanent())
	}
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	if body.item == nil {
		return errs.new(.NotFound, "job: Apply requires a conflicted job output window", allocator = permanent())
	}
	buffer := editor_buffer_for_view(body.item)
	if buffer == nil {
		return errs.new(.Internal, "job: Apply source window has no buffer", allocator = permanent())
	}
	return editor_job_apply_conflict(buffer)
}

editor_command_del :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	if target.window_id != 0 {
		if editor.active_window != target.window_id {
			editor_activate_window(target.window_id)
		}
		editor_request_close(.Close_View, .Tag_Command)
	}
	return {}
}

editor_command_exit :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	editor_request_close(.Quit, .Tag_Command)
	return {}
}

editor_command_new :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	column_id := editor_look_column(target)
	if column_id == 0 {
		return errs.new(.NotFound, "view: no column is available for New", allocator = permanent())
	}
	remaining := invocation.argument
	for {
		path_argument, ok := strings.fields_iterator(&remaining)
		if !ok {
			break
		}
		path, path_err := editor_normalized_look_path(path_argument, target, context.temp_allocator)
		if !errs.ok(path_err) {
			return path_err
		}
		defer delete(path, context.temp_allocator)
		buffer, alloc_err := editor_alloc_path_buffer(path)
		if !errs.ok(alloc_err) {
			return alloc_err
		}
		item, open_err := editor_open_buffer_in_column(buffer, column_id)
		if !errs.ok(open_err) {
			return open_err
		}
		editor_activate_window(item.window_id)
		log.infof("view: New window=%d buffer=%d path=%q", u64(item.window_id), u64(buffer.id), path)
	}
	if strings.trim_space(invocation.argument) == "" {
		buffer, alloc_err := editor_alloc_buffer("")
		if !errs.ok(alloc_err) {
			return alloc_err
		}
		item, open_err := editor_open_buffer_in_column(buffer, column_id)
		if !errs.ok(open_err) {
			return open_err
		}
		editor_activate_window(item.window_id)
		log.infof("view: New window=%d buffer=%d", u64(item.window_id), u64(buffer.id))
	}
	return {}
}

editor_command_newcol :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	column_id, column_err := layout.add_column(&editor.workspace)
	if !errs.ok(column_err) {
		return column_err
	}
	buffer, alloc_err := editor_alloc_buffer("")
	if !errs.ok(alloc_err) {
		layout.remove_column(&editor.workspace, column_id)
		return alloc_err
	}
	if tag_err := editor_init_column_tag(column_id); !errs.ok(tag_err) {
		editor_destroy_buffer(buffer)
		layout.remove_column(&editor.workspace, column_id)
		return tag_err
	}
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		editor_destroy_column_tag(column_id)
		layout.remove_column(&editor.workspace, column_id)
		return open_err
	}
	editor_activate_window(item.window_id)
	log.infof("view: Newcol column=%d window=%d buffer=%d", u64(column_id), u64(item.window_id), u64(buffer.id))
	return {}
}

editor_command_zerox :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	source_item := body.item
	if source_item == nil {
		source_item = editor_active_view()
	}
	if source_item == nil {
		return errs.new(.Invalid_Input, "view: Zerox requires a window body", allocator = permanent())
	}
	buffer := editor_buffer_for_view(source_item)
	if buffer == nil {
		return errs.new(.Internal, "view: Zerox window has no buffer", allocator = permanent())
	}
	if buffer.kind == .Directory {
		return errs.new(.Unsupported, "view: directory windows cannot be Zeroxed", allocator = permanent())
	}
	column_id := editor_look_column(target)
	item, open_err := editor_open_buffer_in_column(buffer, column_id, false)
	if !errs.ok(open_err) {
		return open_err
	}
	item.selection = source_item.selection
	item.first_line = source_item.first_line
	item.first_row = source_item.first_row
	item.wheel_remainder = source_item.wheel_remainder
	item.wrap_mode = source_item.wrap_mode
	item.horizontal_offset = source_item.horizontal_offset
	item.line_numbers = source_item.line_numbers
	editor_activate_window(item.window_id)
	log.infof("view: Zerox window=%d buffer=%d from=%d", u64(item.window_id), u64(buffer.id), u64(source_item.window_id))
	return {}
}

editor_command_delcol :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	column_id := editor_look_column(target)
	if column_id == 0 {
		return errs.new(.NotFound, "view: no column is available for Delcol", allocator = permanent())
	}
	return editor_request_close_column(column_id)
}

editor_command_get :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	if body.item == nil {
		return errs.new(.Invalid_Input, "get: no current window", allocator = permanent())
	}
	buffer := editor_buffer_for_view(body.item)
	if buffer == nil {
		return errs.new(.Internal, "get: current window has no buffer", allocator = permanent())
	}
	path := buffer.path
	owned_path := false
	defer if owned_path {
		delete(path, context.temp_allocator)
	}
	if invocation.argument != "" {
		resolved, path_err := editor_normalized_look_path(invocation.argument, target, context.temp_allocator)
		if !errs.ok(path_err) {
			return path_err
		}
		path = resolved
		owned_path = true
	} else if buffer.kind == .File {
		// The leftmost filepath token of the tag is editable (M09.detour-1);
		// read it so Get can target a different file than the current one.
		filepath, fp_err := tagstate.filepath(&body.item.tag, context.temp_allocator)
		if !errs.ok(fp_err) {
			return fp_err
		}
		defer delete(filepath, context.temp_allocator)
		if filepath != "" && filepath != editor_file_basename(buffer.path) {
			resolved, resolve_err := editor_normalized_look_path(filepath, target, context.temp_allocator)
			if !errs.ok(resolve_err) {
				return resolve_err
			}
			path = resolved
			owned_path = true
		}
	}
	return editor_reload_buffer(body.item, path)
}

editor_command_putall :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	editor_putall()
	return {}
}

editor_command_put :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	if target.window_id == 0 {
		return {}
	}
	if editor.active_window != target.window_id {
		editor_activate_window(target.window_id)
	}
	body := editor_target_body(target)
	item := body.item
	buffer := editor_buffer_for_view(item)
	if buffer != nil && buffer.kind == .File && buffer.path == "" {
		// An untitled buffer's leftmost tag token names the new file.
		filepath, fp_err := tagstate.filepath(&item.tag, context.temp_allocator)
		if !errs.ok(fp_err) {
			return fp_err
		}
		defer delete(filepath, context.temp_allocator)
		if filepath == "" || filepath == "New" {
			return errs.new(.Invalid_Input, "put: type a file name in the tag before Put", allocator = permanent())
		}
		resolved, resolve_err := editor_normalized_look_path(filepath, target, context.temp_allocator)
		if !errs.ok(resolve_err) {
			return resolve_err
		}
		defer delete(resolved, context.temp_allocator)
		return editor_save_buffer_as(buffer, resolved)
	}
	editor_save()
	return {}
}

editor_command_edit :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	if body.doc == nil || body.selection == nil || body.item == nil {
		return errs.new(.Invalid_Input, "edit: no current window", allocator = permanent())
	}
	buffer := editor_buffer_for_view(body.item)
	if buffer == nil {
		return errs.new(.Internal, "edit: current window has no buffer", allocator = permanent())
	}

	script := invocation.argument
	owned: []byte
	if cmd_context.argument_chord {
		selected, ok := editor_command_argument_target(&cmd_context.argument)
		if !ok {
			return errs.new(.Conflict, "edit: chord argument is no longer current", allocator = permanent())
		}
		data, err := mouse.read_action_text(selected.doc, editing.selection_range(selected.selection^), context.temp_allocator)
		if !errs.ok(err) {
			return err
		}
		owned = data
		script = string(data)
	}
	if owned != nil {
		defer delete(owned, context.temp_allocator)
	}
	if strings.trim_space(script) == "" {
		return {}
	}

	program, parse_err := edit.parse(script, permanent())
	if !errs.ok(parse_err) {
		return parse_err
	}
	defer edit.program_destroy(&program, permanent())

	editor.typing_group = 0
	editor.next_group += 1
	if editor.next_group == 0 {
		editor.next_group = 1
	}
	editor.next_edit_request += 1
	if editor.next_edit_request == 0 {
		editor.next_edit_request = 1
	}
	start_err := edit.runner_start(
		&editor.edit_runner,
		body.doc,
		body.selection^,
		&program,
		buffer.regex_history,
		u64(buffer.id),
		buffer.generation,
		txn.doc_revision(&buffer.doc),
		edit.Request_ID(editor.next_edit_request),
		editor.next_group,
		permanent(),
	)
	if errs.ok(start_err) {
		editor.edit_window = body.window_id
		editor.edit_request = edit.Request_ID(editor.next_edit_request)
		log.infof(
			"edit: scheduled window=%d request=%d commands=%d revision=%d",
			u64(body.window_id),
			editor.next_edit_request,
			len(program.commands),
			txn.doc_revision(&buffer.doc),
		)
	}
	return start_err
}

editor_cancel_edit :: proc() -> bool {
	if !edit.runner_active(&editor.edit_runner) {
		return false
	}
	edit.runner_cancel(&editor.edit_runner)
	log.info("edit: cancellation requested")
	return true
}

editor_poll_edit :: proc() {
	result, ok := edit.runner_poll(&editor.edit_runner)
	if !ok {
		return
	}
	window_id := editor.edit_window
	expected_request := editor.edit_request
	request_id := result.request_id
	buffer := editor_buffer_by_id(view.Buffer_ID(result.target_id))
	item, found := view.find(&editor.views, window_id)
	apply_err: errs.Error
	transactions := 0
	if buffer == nil || !found || item.buffer_id != view.Buffer_ID(result.target_id) {
		apply_err = errs.newf(
			.Conflict,
			"edit: result target window or buffer is no longer current (request %d)",
			u64(request_id),
			allocator = permanent(),
		)
	} else {
		first_log := len(buffer.doc.log)
		previous_revision := txn.doc_revision(&buffer.doc)
		apply_err = edit.apply_result(
			&buffer.doc,
			&item.selection,
			&buffer.regex_history,
			result,
			u64(buffer.id),
			buffer.generation,
			expected_request,
			permanent(),
		)
		for index in first_log ..< len(buffer.doc.log) {
			entry := &buffer.doc.log[index]
			byte_count := 0 if entry.after_root == nil else entry.after_root.metrics.byte_count
			view.transform_after_edit(&editor.views, window_id, item.buffer_id, entry.ops, byte_count)
		}
		transactions = len(buffer.doc.log) - first_log
		if txn.doc_revision(&buffer.doc) != previous_revision {
			editor_refresh_window_tags()
		}
		log.infof(
			"edit: completed request=%d transactions=%d revision=%d status=%v",
			u64(request_id),
			transactions,
			txn.doc_revision(&buffer.doc),
			apply_err.kind,
		)
	}
	if apply_err.kind == .Cancelled {
		log.infof("edit: cancelled request=%d", u64(request_id))
		errs.destroy(&apply_err)
	} else {
		editor_report(apply_err)
	}
	edit.runner_release(&editor.edit_runner)
	editor.edit_window = 0
	editor.edit_request = 0
}

editor_command_undo :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	editor_execute_history(editor_command_source_target(cmd_context.source), false)
	return {}
}

editor_command_redo :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	editor_execute_history(editor_command_source_target(cmd_context.source), true)
	return {}
}

editor_command_cut :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if selected, ok := editor_command_argument_target(&cmd_context.argument); ok {
		editor_cut_target(selected)
	} else {
		log.warn("mouse: Cut/Snarf requires a current button-1 selection")
	}
	return {}
}

editor_command_snarf :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if selected, ok := editor_command_argument_target(&cmd_context.argument); ok {
		editor_copy_target(selected)
	} else {
		log.warn("mouse: Cut/Snarf requires a current button-1 selection")
	}
	return {}
}

editor_command_wait :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "job: Wait takes no arguments", allocator = permanent())
	}
	if err := lifecycle.job_quit_decision(&editor.job_quit, .Wait); !errs.ok(err) {
		return err
	}
	log.info("job: quit waiting for jobs and output to complete")
	return {}
}

editor_command_stop :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "job: Stop takes no arguments", allocator = permanent())
	}
	phase := editor.job_quit.phase
	if phase == .Await_Decision || phase == .Waiting || phase == .Cancelling {
		if phase != .Cancelling {
			if err := lifecycle.job_quit_decision(&editor.job_quit, .Cancel_Jobs); !errs.ok(err) {
				return err
			}
		}
		stopped := process.job_stop_all(&editor.jobs, mouse_now_ms())
		log.infof("job: Stop requested for %d job(s) during quit", stopped)
		return {}
	}
	attachment := u64(cmd_context.source.window_id)
	stopped := 0
	if attachment == 0 {
		stopped = process.job_stop_all(&editor.jobs, mouse_now_ms())
	} else {
		stopped = process.job_stop_attachment(&editor.jobs, attachment, mouse_now_ms())
	}
	if stopped == 0 {
		return errs.new(.NotFound, "job: no running job matches Stop", allocator = permanent())
	}
	log.infof("job: Stop requested for %d job(s) attached to window %d", stopped, attachment)
	return {}
}

editor_command_paste :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if selected, ok := editor_command_argument_target(&cmd_context.argument); ok {
		editor_paste_target(selected)
	} else {
		log.warn("mouse: Paste requires a current button-1 selection")
	}
	return {}
}

editor_command_look :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	if target.doc == nil {
		return {}
	}
	body := editor_target_body(target)
	needle := transmute([]byte)invocation.argument
	owned: []byte
	if invocation.argument == "" && cmd_context.argument_chord {
		if selected, ok := editor_command_argument_target(&cmd_context.argument); ok {
			arg_range := editing.selection_range(selected.selection^)
			arg, err := mouse.read_action_text(selected.doc, arg_range, context.temp_allocator)
			if !errs.ok(err) {
				return err
			}
			owned = arg
			needle = owned
		}
	} else if invocation.argument == "" && body.selection != nil {
		selected_range := editing.selection_range(body.selection^)
		arg, err := mouse.read_action_text(body.doc, selected_range, context.temp_allocator)
		if !errs.ok(err) {
			return err
		}
		owned = arg
		needle = owned
	}
	if owned != nil {
		defer delete(owned, context.temp_allocator)
	}
	editor_look_text(target, needle, false)
	return {}
}

editor_execute_history :: proc(target: Mouse_Text_Target, redo: bool) {
	body := editor_target_body(target)
	if body.doc == nil || body.selection == nil {
		return
	}
	selection: txn.Selection
	err: errs.Error
	if redo {
		selection, err = txn.doc_redo(body.doc)
	} else {
		selection, err = txn.doc_undo(body.doc)
	}
	if !errs.ok(err) {
		if err.kind != .NotFound {
			editor_report(err)
		} else {
			errs.destroy(&err)
		}
		return
	}
	body.selection^ = selection
	editor_finish_history_jump(body.item)
}
