package main

import "core:log"

import command "core/command"
import errs "core/errs"
import process "core/process"
import rope "core/rope"

// editor_external_shell returns the configured shell, or the platform default
// when the config leaves it empty. External commands always run through this
// shell; there is no trust gate.
editor_external_shell :: proc() -> string {
	if cfg.Shell != "" {
		return cfg.Shell
	}
	return command.pipe_default_shell()
}

// editor_execute_external is the entry point for `>`, `<`, `|`, and plain
// (unknown) commands. It cancels any pending quit and starts the command as a job.
editor_execute_external :: proc(target: Mouse_Text_Target, command_range: rope.Byte_Range, routing: command.Pipe_Routing, command_text: string) {
	editor_cancel_job_quit()
	log.infof("mouse: execute %q routing=%s target=%d", command_text, command.pipe_routing_name(routing), u64(target.id))
	cmd_context := editor_command_context(target, command_range, false)
	err := editor_run_external(&cmd_context, routing, command_text)
	editor_report(err)
}

// editor_run_external builds the shell command vector and an immutable context
// snapshot. Selection routing requires a source body; plain commands do not.
editor_run_external :: proc(cmd_context: ^command.Context, routing: command.Pipe_Routing, command_text: string) -> errs.Error {
	if command_text == "" {
		return errs.new(.Invalid_Input, "shell: command text is empty", allocator = permanent())
	}
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	buffer: ^Editor_Buffer
	if routing != .Plain {
		if body.doc == nil || body.selection == nil || body.item == nil {
			return errs.new(.NotFound, "shell: selection routing requires a body window", allocator = permanent())
		}
		buffer = editor_buffer_for_view(body.item)
		if buffer == nil {
			return errs.new(.Internal, "shell: source window has no buffer", allocator = permanent())
		}
	}

	argv, argv_err := command.pipe_shell_command(editor_external_shell(), command_text, context.temp_allocator)
	if !errs.ok(argv_err) {
		return argv_err
	}
	defer command.pipe_argv_destroy(argv, context.temp_allocator)

	snapshot: process.Context_Snapshot
	if snapshot_err := process.context_snapshot_init(&snapshot, editor_filter_context_description(cmd_context.source), context.temp_allocator); !errs.ok(snapshot_err) {
		return snapshot_err
	}
	defer process.context_snapshot_destroy(&snapshot)

	return editor_run_external_job(argv, &snapshot, routing, body, buffer)
}

// editor_run_external_job starts the command through the job service. Replace,
// feed, and pipe output replaces the selection after validation. Plain commands
// use reusable output windows; explicitly discarded jobs have no output.
editor_run_external_job :: proc(argv: []string, snapshot: ^process.Context_Snapshot, routing: command.Pipe_Routing, body: Mouse_Text_Target, buffer: ^Editor_Buffer) -> errs.Error {
	desc := process.Description{command = argv, working_dir = snapshot.working_dir, environment = snapshot.environment}
	switch routing {
	case .Pipe:
		id, start_err := process.job_start_selection(&editor.jobs, desc, &buffer.doc, body.selection^, u64(buffer.id), buffer.generation, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started pipe id=%d", u64(id))
	case .Replace:
		id, start_err := process.job_start_selection(
			&editor.jobs,
			desc,
			&buffer.doc,
			body.selection^,
			u64(buffer.id),
			buffer.generation,
			u64(body.window_id),
			{empty_input = true},
		)
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started replace id=%d", u64(id))
	case .Feed:
		id, start_err := process.job_start_selection(&editor.jobs, desc, &buffer.doc, body.selection^, u64(buffer.id), buffer.generation, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started feed id=%d", u64(id))
	case .Plain:
		id, start_err := process.job_start_context(&editor.jobs, argv, snapshot, nil, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		job := process.job_find(&editor.jobs, id)
		if job == nil {
			return errs.new(.Internal, "shell: started command has no job slot", allocator = permanent())
		}
		job.reuse_output = true
		editor_job_output_detach_reused(job)
		log.infof("shell: started command id=%d", u64(id))
	}
	return {}
}
