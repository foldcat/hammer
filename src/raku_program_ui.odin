package main

import "core:log"
import "core:os"
import "core:strings"

import command "core/command"
import errs "core/errs"
import process "core/process"

// editor_raku_temp_program writes one explicitly invoked program and closes it
// before spawn. The caller owns the returned path string. File cleanup moves to
// the job after job_track_temporary_file succeeds; the caller still deletes the
// returned string with the same allocator.
editor_raku_temp_program :: proc(body: string, allocator := context.temp_allocator) -> (path: string, err: errs.Error) {
	if body == "" || len(body) > command.MAX_FILTER_BODY_BYTES {
		return "", errs.new(.Invalid_Input, "raku: program is empty or exceeds the source budget", allocator = permanent())
	}
	file, create_err := os.create_temp_file("", "hammer-raku-*.raku")
	if create_err != nil {
		return "", errs.newf(.IO, "raku: cannot create temporary program: %v", create_err, allocator = permanent())
	}
	open := true
	succeeded := false
	path = strings.clone(os.name(file), allocator)
	defer {
		if open {
			os.close(file)
		}
		if !succeeded {
			if path != "" {
				os.remove(path)
				delete(path, allocator)
			}
		}
	}
	if path == "" {
		os.remove(os.name(file))
		return "", errs.new(.Resource_Limit, "raku: cannot copy temporary program path", allocator = permanent())
	}
	data := transmute([]byte)body
	for written := 0; written < len(data); {
		count, write_err := os.write(file, data[written:])
		if write_err != nil {
			return "", errs.newf(.IO, "raku: cannot write temporary program: %v", write_err, allocator = permanent())
		}
		if count <= 0 {
			return "", errs.new(.IO, "raku: short write to temporary program", allocator = permanent())
		}
		written += count
	}
	if flush_err := os.flush(file); flush_err != nil {
		return "", errs.newf(.IO, "raku: cannot flush temporary program: %v", flush_err, allocator = permanent())
	}
	if close_err := os.close(file); close_err != nil {
		open = false
		return "", errs.newf(.IO, "raku: cannot close temporary program: %v", close_err, allocator = permanent())
	}
	open = false
	succeeded = true
	return path, {}
}

editor_raku_track_program :: proc(id: process.Job_ID, path: string) -> errs.Error {
	if err := process.job_track_temporary_file(&editor.jobs, id, path); !errs.ok(err) {
		_, stop_err := process.job_stop(&editor.jobs, id, mouse_now_ms())
		editor_report(stop_err)
		return err
	}
	return {}
}

editor_command_raku_eval :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument == "" {
		return errs.new(.Invalid_Input, "raku: RakuEval requires a one-line program", allocator = permanent())
	}
	engine_path, resolve_err := command.filter_engine_resolve(&editor.filters, "raku")
	if !errs.ok(resolve_err) {
		return resolve_err
	}
	defer delete(engine_path, context.temp_allocator)
	if engine_path == "" {
		return errs.new(.Unsupported, "raku: RakuEval requires raku on PATH", allocator = permanent())
	}
	program_path, program_err := editor_raku_temp_program(invocation.argument)
	if !errs.ok(program_err) {
		return program_err
	}
	tracked := false
	defer {
		if !tracked {
			os.remove(program_path)
		}
		delete(program_path, context.temp_allocator)
	}
	argv, argv_err := command.raku_program_command(engine_path, "", program_path, context.temp_allocator)
	if !errs.ok(argv_err) {
		return argv_err
	}
	defer command.raku_program_command_destroy(argv, context.temp_allocator)
	snapshot: process.Context_Snapshot
	if snapshot_err := process.context_snapshot_init(&snapshot, editor_filter_context_description(cmd_context.source), context.temp_allocator); !errs.ok(snapshot_err) {
		return snapshot_err
	}
	defer process.context_snapshot_destroy(&snapshot)
	input, input_err := editor_raku_input(cmd_context.source)
	if !errs.ok(input_err) {
		return input_err
	}
	defer delete(input, context.temp_allocator)

	log.infof("raku: echo %q", invocation.argument)
	id, start_err := process.job_start_context(&editor.jobs, argv, &snapshot, input, u64(cmd_context.source.window_id))
	if !errs.ok(start_err) {
		return start_err
	}
	if track_err := editor_raku_track_program(id, program_path); !errs.ok(track_err) {
		return track_err
	}
	tracked = true
	log.infof("raku: one-liner started id=%d path=%s", u64(id), program_path)
	return {}
}

editor_command_raku_repl :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "raku: RakuRepl takes no arguments", allocator = permanent())
	}
	engine_path, resolve_err := command.filter_engine_resolve(&editor.filters, "raku")
	if !errs.ok(resolve_err) {
		return resolve_err
	}
	defer delete(engine_path, context.temp_allocator)
	if engine_path == "" {
		return errs.new(.Unsupported, "raku: RakuRepl requires raku on PATH", allocator = permanent())
	}
	if err := editor_open_terminal(cmd_context, {engine_path}, "Raku REPL"); !errs.ok(err) {
		return err
	}
	log.infof("raku: REPL opened engine=%s", engine_path)
	return {}
}
