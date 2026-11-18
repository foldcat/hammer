package main

import "core:log"
import "core:strings"

import command "core/command"
import editing "core/editing"
import errs "core/errs"
import mouse "core/mouse"
import rope "core/rope"
import txn "core/txn"

EDITOR_COMMANDS :: []command.Entry {
	{name = "Del", handler = editor_command_del},
	{name = "Exit", handler = editor_command_exit},
	{name = "Put", handler = editor_command_put},
	{name = "Undo", handler = editor_command_undo},
	{name = "Redo", handler = editor_command_redo},
	{name = "Cut", handler = editor_command_cut},
	{name = "Snarf", handler = editor_command_snarf},
	{name = "Paste", handler = editor_command_paste},
	{name = "Look", handler = editor_command_look},
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
	if strings.trim_space(string(data)) == "" {
		return
	}
	invocation, parse_err := command.parse(string(data), context.temp_allocator)
	if !errs.ok(parse_err) {
		editor_report(parse_err)
		return
	}
	log.infof("mouse: execute %q target=%d argument_chord=%v", invocation.name, u64(action.target), action.with_argument)
	cmd_context := editor_command_context(target, range, action.with_argument)
	handled, dispatch_err := command.dispatch(EDITOR_COMMANDS, invocation, &cmd_context, context.temp_allocator)
	if !handled && dispatch_err.kind == .NotFound {
		log.warnf("mouse: command %q was not executed; no handler is registered", invocation.name)
		errs.destroy(&dispatch_err)
		return
	}
	editor_report(dispatch_err)
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

editor_command_put :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	if target.window_id != 0 {
		if editor.active_window != target.window_id {
			editor_activate_window(target.window_id)
		}
		editor_save()
	}
	return {}
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
