package main

import "core:fmt"
import "core:log"
import "core:os"

import command "core/command"
import editing "core/editing"
import errs "core/errs"
import layout "core/layout"
import process "core/process"
import rope "core/rope"
import view "core/view"

// editor_filter_context_description builds an immutable context description
// from a command source. When the source names a body window, the body buffer
// supplies the stable buffer ID, directory flag, and file path; otherwise the
// tag identity is used and the file path stays borrowed from the source.
editor_filter_context_description :: proc(source: command.Source) -> process.Context_Description {
	desc := process.Context_Description{
		window_id = source.window_id,
		buffer_id = source.buffer_id,
		file_path = source.file_path,
	}
	if source.window_id == 0 {
		return desc
	}
	if item, found := view.find(&editor.views, layout.Window_ID(source.window_id)); found {
		if buffer := editor_buffer_for_view(item); buffer != nil {
			desc.buffer_id = u64(buffer.id)
			desc.file_is_directory = buffer.kind == .Directory
			if buffer.path != "" {
				desc.file_path = buffer.path
			}
		}
	}
	return desc
}

// editor_filter_echo records the resolved invocation in +Errors before the job
// starts. The log line is the stable test hook; the buffer line is the user
// signal.
editor_filter_echo :: proc(name, engine, body: string) {
	log.infof("filter: echo %q", name)
	line := fmt.aprintf("%s %s", engine, body, allocator = context.temp_allocator)
	if line == "" {
		return
	}
	defer delete(line, context.temp_allocator)
	editor_report(editor_append_error(line))
}

// editor_raku_input snapshots a non-empty selection, or the whole current
// unsaved buffer when the selection is a caret. Global-tag invocations use the
// active window so RakuEval remains usable there.
editor_raku_input :: proc(source: command.Source) -> ([]byte, errs.Error) {
	target := editor_command_source_target(source)
	body := editor_target_body(target)
	if body.doc == nil && source.window_id == 0 {
		if item := editor_active_view(); item != nil {
			body = editor_text_target_by_id(editor_body_target_id(item.window_id))
		}
	}
	if body.doc == nil || body.selection == nil {
		return nil, errs.new(.NotFound, "raku: command has no source buffer", allocator = permanent())
	}
	range := rope.Byte_Range{0, rope.tree_byte_count(&body.doc.tree)}
	selected := editing.selection_range(body.selection^)
	if selected.start != selected.end {
		range = selected
	}
	if range.end - range.start > process.MAX_SELECTION_INPUT_BYTES {
		return nil, errs.newf(.Resource_Limit, "raku: input exceeds the %d-byte budget", process.MAX_SELECTION_INPUT_BYTES, allocator = permanent())
	}
	return rope.tree_read_all(&body.doc.tree, range, context.temp_allocator)
}

// editor_invoke_filter runs a named filter when the invocation name matches a
// registry entry. handled reports whether the name matched a definition; the
// returned error is nil when the name is unknown.
editor_invoke_filter :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> (handled: bool, err: errs.Error) {
	definition := command.filter_registry_find(&editor.filters, invocation.name)
	if definition == nil {
		return false, {}
	}
	if invocation.argument != "" {
		return true, errs.newf(.Invalid_Input, "filter: %s takes no arguments", invocation.name, allocator = permanent())
	}
	if definition.engine_path == "" {
		return true, errs.newf(.Unsupported, "filter: %s engine %q is not available", invocation.name, definition.engine, allocator = permanent())
	}

	is_raku := definition.engine == "raku"
	program_path := ""
	program_tracked := false
	defer if program_path != "" {
		if !program_tracked {
			os.remove(program_path)
		}
		delete(program_path, context.temp_allocator)
	}
	argv: []string
	if is_raku {
		path, program_err := editor_raku_temp_program(definition.body)
		if !errs.ok(program_err) {
			return true, program_err
		}
		program_path = path
		raku_argv, raku_argv_err := command.raku_program_command(definition.engine_path, definition.raku_mode, program_path, context.temp_allocator)
		if !errs.ok(raku_argv_err) {
			return true, raku_argv_err
		}
		argv = raku_argv
	} else {
		filter_argv, filter_argv_err := command.filter_command(definition, context.temp_allocator)
		if !errs.ok(filter_argv_err) {
			return true, filter_argv_err
		}
		argv = filter_argv
	}
	defer {
		if is_raku {
			command.raku_program_command_destroy(argv, context.temp_allocator)
		} else {
			command.filter_command_destroy(argv, context.temp_allocator)
		}
	}

	snapshot: process.Context_Snapshot
	if snapshot_err := process.context_snapshot_init(&snapshot, editor_filter_context_description(cmd_context.source), context.temp_allocator); !errs.ok(snapshot_err) {
		return true, snapshot_err
	}
	defer process.context_snapshot_destroy(&snapshot)

	if is_raku {
		log.infof("filter: echo %q", invocation.name)
	} else {
		editor_filter_echo(invocation.name, definition.engine, definition.body)
	}

	id: process.Job_ID
	switch definition.routing {
	case .Replace_Selection:
		item, found := view.find(&editor.views, layout.Window_ID(cmd_context.source.window_id))
		if !found {
			return true, errs.new(.NotFound, "filter: replace-selection has no source window", allocator = permanent())
		}
		buffer := editor_buffer_for_view(item)
		if buffer == nil {
			return true, errs.new(.Internal, "filter: source window has no buffer", allocator = permanent())
		}
		pipe_options: process.Selection_Pipe_Options
		if is_raku {
			pipe_options.whole_buffer_input_when_empty = true
		}
		started_id, start_err := process.job_start_selection(
			&editor.jobs,
			{command = argv, working_dir = snapshot.working_dir, environment = snapshot.environment},
			&buffer.doc,
			item.selection,
			u64(buffer.id),
			buffer.generation,
			u64(item.window_id),
			pipe_options,
		)
		if !errs.ok(start_err) {
			return true, start_err
		}
		id = started_id
		log.infof("filter: %s started replace-selection id=%d", invocation.name, u64(id))
	case .Output_Window:
		input: []byte
		if is_raku {
			selection_input, input_err := editor_raku_input(cmd_context.source)
			if !errs.ok(input_err) {
				return true, input_err
			}
			input = selection_input
		}
		started_id, start_err := process.job_start_context(&editor.jobs, argv, &snapshot, input, u64(cmd_context.source.window_id))
		if input != nil {
			delete(input, context.temp_allocator)
		}
		if !errs.ok(start_err) {
			return true, start_err
		}
		id = started_id
		log.infof("filter: %s started output-window id=%d", invocation.name, u64(id))
	case .Discard:
		input: []byte
		if is_raku {
			selection_input, input_err := editor_raku_input(cmd_context.source)
			if !errs.ok(input_err) {
				return true, input_err
			}
			input = selection_input
		}
		started_id, start_err := process.job_start_context_discard_input(&editor.jobs, argv, &snapshot, input, u64(cmd_context.source.window_id))
		if input != nil {
			delete(input, context.temp_allocator)
		}
		if !errs.ok(start_err) {
			return true, start_err
		}
		id = started_id
		log.infof("filter: %s started discard id=%d", invocation.name, u64(id))
	}
	if program_path != "" {
		if track_err := editor_raku_track_program(id, program_path); !errs.ok(track_err) {
			return true, track_err
		}
		program_tracked = true
	}
	return true, {}
}
