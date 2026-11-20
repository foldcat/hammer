package main

import "core:fmt"
import "core:log"

import command "core/command"
import errs "core/errs"
import layout "core/layout"
import process "core/process"
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

	argv, argv_err := command.filter_command(definition, context.temp_allocator)
	if !errs.ok(argv_err) {
		return true, argv_err
	}
	defer command.filter_command_destroy(argv, context.temp_allocator)

	snapshot: process.Context_Snapshot
	if snapshot_err := process.context_snapshot_init(&snapshot, editor_filter_context_description(cmd_context.source), context.temp_allocator); !errs.ok(snapshot_err) {
		return true, snapshot_err
	}
	defer process.context_snapshot_destroy(&snapshot)

	editor_filter_echo(invocation.name, definition.engine, definition.body)

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
		id, start_err := process.job_start_selection(
			&editor.jobs,
			{command = argv, working_dir = snapshot.working_dir, environment = snapshot.environment},
			&buffer.doc,
			item.selection,
			u64(buffer.id),
			buffer.generation,
			u64(item.window_id),
		)
		if !errs.ok(start_err) {
			return true, start_err
		}
		log.infof("filter: %s started replace-selection id=%d", invocation.name, u64(id))
	case .Output_Window:
		id, start_err := process.job_start_context(&editor.jobs, argv, &snapshot, nil, u64(cmd_context.source.window_id))
		if !errs.ok(start_err) {
			return true, start_err
		}
		log.infof("filter: %s started output-window id=%d", invocation.name, u64(id))
	case .Discard:
		id, start_err := process.job_start_context_discard(&editor.jobs, argv, &snapshot, u64(cmd_context.source.window_id))
		if !errs.ok(start_err) {
			return true, start_err
		}
		log.infof("filter: %s started discard id=%d", invocation.name, u64(id))
	}
	return true, {}
}
