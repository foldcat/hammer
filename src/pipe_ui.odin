package main

import "core:io"
import "core:log"
import "core:os"

import command "core/command"
import editing "core/editing"
import errs "core/errs"
import process "core/process"
import rope "core/rope"
import txn "core/txn"

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
// (unknown) commands. It cancels any pending quit and runs the command through
// the shell, synchronously unless `async` is set.
editor_execute_external :: proc(target: Mouse_Text_Target, command_range: rope.Byte_Range, routing: command.Pipe_Routing, command_text: string, async: bool) {
	editor_cancel_job_quit()
	log.infof("mouse: execute %q routing=%s async=%v target=%d", command_text, command.pipe_routing_name(routing), async, u64(target.id))
	cmd_context := editor_command_context(target, command_range, false)
	err := editor_run_external(&cmd_context, routing, command_text, async)
	editor_report(err)
}

// editor_run_external resolves the source body window, builds the shell
// command vector and an immutable context snapshot, then runs the command
// synchronously or asynchronously.
editor_run_external :: proc(cmd_context: ^command.Context, routing: command.Pipe_Routing, command_text: string, async: bool) -> errs.Error {
	if command_text == "" {
		return errs.new(.Invalid_Input, "shell: command text is empty", allocator = permanent())
	}
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	if body.doc == nil || body.selection == nil || body.item == nil {
		return errs.new(.NotFound, "shell: no body window for the external command", allocator = permanent())
	}
	buffer := editor_buffer_for_view(body.item)
	if buffer == nil {
		return errs.new(.Internal, "shell: source window has no buffer", allocator = permanent())
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

	if async {
		return editor_run_external_async(argv, &snapshot, routing, body, buffer)
	}
	return editor_run_external_sync(argv, &snapshot, routing, body, buffer)
}

// editor_run_external_async starts the command through the job service. Output
// for replace/pipe replaces the selection asynchronously; feed/plain output
// opens an output window.
editor_run_external_async :: proc(argv: []string, snapshot: ^process.Context_Snapshot, routing: command.Pipe_Routing, body: Mouse_Text_Target, buffer: ^Editor_Buffer) -> errs.Error {
	desc := process.Description{command = argv, working_dir = snapshot.working_dir, environment = snapshot.environment}
	switch routing {
	case .Pipe:
		id, start_err := process.job_start_selection(&editor.jobs, desc, &buffer.doc, body.selection^, u64(buffer.id), buffer.generation, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started async pipe id=%d", u64(id))
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
		log.infof("shell: started async replace id=%d", u64(id))
	case .Feed:
		input, read_err := editor_pipe_feed_input(body)
		if !errs.ok(read_err) {
			return read_err
		}
		defer delete(input, context.temp_allocator)
		id, start_err := process.job_start_context(&editor.jobs, argv, snapshot, input, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started async feed id=%d", u64(id))
	case .Plain:
		id, start_err := process.job_start_context(&editor.jobs, argv, snapshot, nil, u64(body.window_id))
		if !errs.ok(start_err) {
			return start_err
		}
		log.infof("shell: started async command id=%d", u64(id))
	}
	return {}
}

// editor_run_external_sync runs the command to completion and applies its
// output in one transaction. This blocks the event loop; long-running or
// flooding commands should use `Async <cmd>`.
editor_run_external_sync :: proc(argv: []string, snapshot: ^process.Context_Snapshot, routing: command.Pipe_Routing, body: Mouse_Text_Target, buffer: ^Editor_Buffer) -> errs.Error {
	input: []byte
	defer if input != nil {
		delete(input, context.temp_allocator)
	}
	switch routing {
	case .Pipe, .Feed:
		read, read_err := editor_pipe_feed_input(body)
		if !errs.ok(read_err) {
			return read_err
		}
		input = read
	case .Replace, .Plain:
	}

	stdout, stderr, status, run_err := editor_shell_run_sync(argv, snapshot, input)
	defer delete(stdout, context.temp_allocator)
	defer delete(stderr, context.temp_allocator)
	if !errs.ok(run_err) {
		editor_append_error_bytes(transmute([]byte)run_err.message)
		errs.destroy(&run_err)
		return {}
	}
	if !status.success {
		log.warnf("shell: command exited with code %d", status.exit_code)
	}

	switch routing {
	case .Pipe, .Replace:
		if replace_err := editor_external_replace(body, buffer, stdout); !errs.ok(replace_err) {
			return replace_err
		}
		if len(stderr) > 0 {
			editor_append_error_bytes(stderr)
		}
	case .Feed, .Plain:
		if len(stdout) > 0 {
			editor_append_error_bytes(stdout)
		}
		if len(stderr) > 0 {
			editor_append_error_bytes(stderr)
		}
	}
	return {}
}

// editor_shell_run_sync runs `argv` to completion through os.process_exec,
// feeding `input` (nil for empty stdin) via a temporary file. The returned
// stdout/stderr are owned by the caller and must be freed.
editor_shell_run_sync :: proc(argv: []string, snapshot: ^process.Context_Snapshot, input: []byte) -> (stdout: []byte, stderr: []byte, status: os.Process_State, err: errs.Error) {
	desc := os.Process_Desc{
		command = argv,
		working_dir = snapshot.working_dir,
		env = snapshot.environment,
	}
	stdin_file: ^os.File
	defer if stdin_file != nil {
		os.remove(os.name(stdin_file))
		os.close(stdin_file)
	}
	if len(input) > 0 {
		file, file_err := os.create_temp_file("", "hammer-pipe-*")
		if file_err != nil {
			err = errs.newf(.IO, "shell: cannot create stdin file: %v", file_err, allocator = permanent())
			return
		}
		stdin_file = file
		for written := 0; written < len(input); {
			n, write_err := os.write(stdin_file, input[written:])
			if write_err != nil {
				err = errs.newf(.IO, "shell: cannot write stdin file: %v", write_err, allocator = permanent())
				return
			}
			if n == 0 {
				break
			}
			written += n
		}
		if flush_err := os.flush(stdin_file); flush_err != nil {
			err = errs.newf(.IO, "shell: cannot flush stdin file: %v", flush_err, allocator = permanent())
			return
		}
		os.seek(stdin_file, 0, io.Seek_From.Start)
		desc.stdin = stdin_file
	}

	state, out, err_out, os_err := os.process_exec(desc, context.temp_allocator)
	stdout = out
	stderr = err_out
	status = state
	if os_err != nil {
		err = errs.newf(.IO, "shell: command failed to run: %v", os_err, allocator = permanent())
		return
	}
	return
}

// editor_pipe_feed_input reads the body selection as the stdin snapshot,
// bounded by the selection-input budget.
editor_pipe_feed_input :: proc(body: Mouse_Text_Target) -> ([]byte, errs.Error) {
	range := editing.selection_range(body.selection^)
	if range.end - range.start > process.MAX_SELECTION_INPUT_BYTES {
		return nil, errs.newf(
			.Resource_Limit,
			"shell: selection exceeds the %d-byte input budget",
			process.MAX_SELECTION_INPUT_BYTES,
			allocator = permanent(),
		)
	}
	return rope.tree_read_all(&body.doc.tree, range, context.temp_allocator)
}

// editor_external_replace replaces the current body selection with the command
// output as one transaction. The synchronous path means there is no stale
// target to validate.
editor_external_replace :: proc(body: Mouse_Text_Target, buffer: ^Editor_Buffer, data: []byte) -> errs.Error {
	range := editing.selection_range(body.selection^)
	after := txn.Selection{anchor = range.start + len(data), active = range.start + len(data), affinity = .Left}
	operation: txn.Operation
	if range.start == range.end {
		operation = txn.Insert{pos = range.start, data = data}
	} else {
		operation = txn.Replace{range = range, data = data}
	}
	transaction := txn.Transaction{
		source = .Command_Output,
		base_revision = txn.doc_revision(&buffer.doc),
		ops = []txn.Operation{operation},
		after_selection = after,
	}
	previous_revision := txn.doc_revision(&buffer.doc)
	if apply_err := txn.doc_apply(&buffer.doc, &transaction, permanent()); !errs.ok(apply_err) {
		return apply_err
	}
	body.selection^ = after
	editor_finish_edit(body.item, previous_revision, {})
	log.infof("shell: selection replaced window=%d buffer=%d bytes=%d", u64(body.window_id), u64(buffer.id), len(data))
	return {}
}
