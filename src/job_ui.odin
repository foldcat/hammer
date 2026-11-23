package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

import command "core/command"
import editing "core/editing"
import errs "core/errs"
import layout "core/layout"
import lifecycle "core/lifecycle"
import mouse "core/mouse"
import process "core/process"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

JOB_FRAME_OUTPUT_BUDGET :: 256 * 1024

Editor_Job_Output :: struct {
	id:             process.Job_ID,
	failed_id:      process.Job_ID,
	buffer:         ^Editor_Buffer,
	output:         process.Output_Buffer,
	pending_error:  string,
	error_reported: bool,
	trim_logged:    bool,
}

editor_job_output_reset :: proc(state: ^Editor_Job_Output) {
	process.output_destroy(&state.output)
	delete(state.pending_error, permanent())
	state^ = {}
}

editor_job_output_close :: proc(buffer: ^Editor_Buffer) {
	if buffer == nil {
		return
	}
	for index in 0 ..< process.MAX_JOBS {
		state := &editor.job_outputs[index]
		if state.buffer != buffer {
			continue
		}
		if job := process.job_find(&editor.jobs, state.id); job != nil {
			job.discard_output = true
			job.attachment = 0
			log.infof("job: output closed id=%d; draining remaining output", u64(job.id))
		}
		editor_job_output_reset(state)
		return
	}
}

editor_job_output_init :: proc(state: ^Editor_Job_Output, job: ^process.Job) -> errs.Error {
	created_column := editor.workspace.column_count == 0
	column_id: layout.Column_ID
	if created_column {
		id, column_err := layout.add_column(&editor.workspace)
		if !errs.ok(column_err) {
			return column_err
		}
		column_id = id
		if tag_err := editor_init_column_tag(column_id); !errs.ok(tag_err) {
			layout.remove_column(&editor.workspace, column_id)
			return tag_err
		}
	} else {
		column_id = editor.workspace.columns[editor.workspace.column_count - 1].id
	}
	keep_column := false
	defer if created_column && !keep_column {
		editor_destroy_column_tag(column_id)
		layout.remove_column(&editor.workspace, column_id)
	}

	buffer, alloc_err := editor_alloc_buffer_content("", nil, .Job_Output)
	if !errs.ok(alloc_err) {
		return alloc_err
	}
	buffer.job_name = fmt.aprintf("+Job %d", u64(job.id), allocator = permanent())
	if buffer.job_name == "" {
		editor_destroy_buffer(buffer)
		return errs.new(.Resource_Limit, "job: cannot allocate output-window name", allocator = permanent())
	}
	output: process.Output_Buffer
	if err := process.output_init(&output, &buffer.doc, {}, permanent()); !errs.ok(err) {
		editor_destroy_buffer(buffer)
		return err
	}
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		process.output_destroy(&output)
		return open_err
	}
	keep_column = true
	state^ = {id = job.id, buffer = buffer, output = output}
	job.attachment = u64(item.window_id)
	log.infof("job: output opened id=%d window=%d buffer=%d column=%d", u64(job.id), u64(item.window_id), u64(buffer.id), u64(column_id))
	return {}
}

editor_job_output_snapshot :: proc(state: ^Editor_Job_Output) -> (was_dirty, follow: bool) {
	buffer := state.buffer
	was_dirty = txn.doc_revision(&buffer.doc) != buffer.saved_revision
	item := editor_first_view_for_buffer(buffer.id)
	if item != nil {
		end := rope.tree_byte_count(&buffer.doc.tree)
		follow = item.selection.anchor == end && item.selection.active == end
	}
	return
}

editor_job_output_apply :: proc(state: ^Editor_Job_Output, was_dirty, follow: bool) {
	if !state.output.has_update {
		return
	}
	buffer := state.buffer
	update := &state.output.update
	item := editor_first_view_for_buffer(buffer.id)
	if item == nil {
		return
	}
	view.transform_after_edit(&editor.views, 0, buffer.id, update.transaction.ops, update.end)
	if follow {
		item.selection = update.transaction.after_selection
	}
	if update.trimmed > 0 {
		line_count := rope.tree_line_count(&buffer.doc.tree)
		item.first_line = clamp(item.first_line, 0, rope.Line_Index(max(0, line_count - 1)))
		if !state.trim_logged {
			state.trim_logged = true
			log.infof("job: output scrollback trimmed id=%d dropped=%d", u64(state.id), state.output.dropped_bytes)
		}
	}
	if !was_dirty {
		buffer.saved_revision = txn.doc_revision(&buffer.doc)
	}
}

editor_job_queue_error :: proc(state: ^Editor_Job_Output, message: string) {
	if state.pending_error != "" {
		return
	}
	bounded := message
	if len(bounded) > process.MAX_OUTPUT_BATCH_BYTES - 1 {
		bounded = bounded[:process.MAX_OUTPUT_BATCH_BYTES - 1]
	}
	state.pending_error = fmt.aprintf("%s\n", bounded, allocator = permanent())
}

editor_job_flush_error :: proc(state: ^Editor_Job_Output, remaining: ^int) -> bool {
	if state.pending_error == "" {
		return true
	}
	if len(state.pending_error) > remaining^ {
		return false
	}
	was_dirty, follow := editor_job_output_snapshot(state)
	err := process.output_append(&state.output, transmute([]byte)state.pending_error)
	if !errs.ok(err) {
		editor_report(err)
		delete(state.pending_error, permanent())
		state.pending_error = ""
		return true
	}
	editor_job_output_apply(state, was_dirty, follow)
	remaining^ -= len(state.pending_error)
	delete(state.pending_error, permanent())
	state.pending_error = ""
	return true
}

editor_job_drain_records :: proc(job: ^process.Job) {
	for {
		_, ok := process.pump_next(&job.pump)
		if !ok {
			break
		}
		process.pump_release(&job.pump)
	}
}

editor_job_apply_selection :: proc(job: ^process.Job) -> errs.Error {
	pipe := &job.selection_pipe
	item, found := view.find(&editor.views, layout.Window_ID(pipe.target.window_id))
	if !found || u64(item.buffer_id) != pipe.target.id {
		process.selection_pipe_reject(pipe)
		return errs.new(.Conflict, "job: selection source view is no longer available", allocator = permanent())
	}
	buffer := editor_buffer_by_id(item.buffer_id)
	if buffer == nil || buffer.generation != pipe.target.generation {
		process.selection_pipe_reject(pipe)
		return errs.new(.Conflict, "job: selection target buffer is no longer available", allocator = permanent())
	}
	previous_revision := txn.doc_revision(&buffer.doc)
	if err := process.selection_pipe_apply(pipe, &buffer.doc, u64(buffer.id), buffer.generation, u64(job.id)); !errs.ok(err) {
		return err
	}
	item.selection = pipe.transaction.after_selection
	editor_finish_edit(item, previous_revision, {})
	log.infof(
		"job: selection replaced id=%d window=%d buffer=%d revision=%d bytes=%d",
		u64(job.id),
		u64(item.window_id),
		u64(buffer.id),
		txn.doc_revision(&buffer.doc),
		pipe.output_len,
	)
	return {}
}

editor_job_apply_regex :: proc(job: ^process.Job) -> errs.Error {
	search := &job.regex_search
	item, found := view.find(&editor.views, layout.Window_ID(search.target.window_id))
	if !found || u64(item.buffer_id) != search.target.id {
		process.regex_search_reject(search)
		return errs.new(.Conflict, "regex: search source view is no longer available", allocator = permanent())
	}
	buffer := editor_buffer_by_id(item.buffer_id)
	if buffer == nil || buffer.generation != search.target.generation {
		process.regex_search_reject(search)
		return errs.new(.Conflict, "regex: search target buffer is no longer available", allocator = permanent())
	}
	match, apply_err := process.regex_search_apply(search, &buffer.doc, u64(buffer.id), buffer.generation, u64(job.id))
	if !errs.ok(apply_err) {
		return apply_err
	}
	item.selection = txn.Selection{anchor = match.start, active = match.end, affinity = .Right}
	editor_reveal_caret(item)
	editor_finish_history_jump(item)
	log.infof("regex: external match id=%d window=%d buffer=%d range=%d,%d", u64(job.id), u64(item.window_id), u64(buffer.id), match.start, match.end)
	return {}
}

editor_job_poll_regex :: proc(job: ^process.Job, state: ^Editor_Job_Output, remaining: ^int) {
	search := &job.regex_search
	if search.state == .Collecting && remaining^ > 0 {
		was_dirty, follow := editor_job_output_snapshot(state)
		consumed, consume_err := process.regex_search_consume(search, &job.pump, &state.output, remaining^)
		remaining^ -= consumed
		editor_job_output_apply(state, was_dirty, follow)
		if !errs.ok(consume_err) {
			editor_job_queue_error(state, consume_err.message)
			errs.destroy(&consume_err)
			if process.job_active(job) {
				_, stop_err := process.job_stop(&editor.jobs, job.id, mouse_now_ms())
				editor_report(stop_err)
			}
		}
	}
	output_done := process.pump_drained(&job.pump)
	if search.state == .Collecting && ((job.state == .Exited && output_done) || job.state == .FailedToStart) {
		if job.state == .Exited && job.exit_status.success && job.err.kind == .None {
			process.regex_search_ready(search)
		} else {
			process.regex_search_abort(search)
			if job.state == .Exited && job.exit_status.code == 4 {
				editor_job_queue_error(state, "regex: regular expression did not match")
			} else if job.state == .Exited && job.err.kind == .None {
				editor_job_queue_error(state, "regex: Raku search failed; see diagnostics")
			}
		}
	}
	if search.state == .Ready {
		apply_err := editor_job_apply_regex(job)
		if !errs.ok(apply_err) {
			log.warnf("regex: external apply failed id=%d kind=%v message=%s", u64(job.id), apply_err.kind, apply_err.message)
			editor_job_queue_error(state, apply_err.message)
			errs.destroy(&apply_err)
		}
	}
}

editor_job_apply_conflict :: proc(output_buffer: ^Editor_Buffer) -> errs.Error {
	if output_buffer == nil || !output_buffer.has_conflict_pipe || output_buffer.conflict_pipe.state != .Conflict {
		return errs.new(.NotFound, "job: no preserved selection conflict is available", allocator = permanent())
	}
	pipe := &output_buffer.conflict_pipe
	item, found := view.find(&editor.views, layout.Window_ID(pipe.target.window_id))
	if !found || u64(item.buffer_id) != pipe.target.id {
		return errs.new(.Conflict, "job: selection source view is no longer available", allocator = permanent())
	}
	buffer := editor_buffer_by_id(item.buffer_id)
	if buffer == nil || buffer.generation != pipe.target.generation {
		return errs.new(.Conflict, "job: selection target buffer is no longer available", allocator = permanent())
	}
	previous_revision := txn.doc_revision(&buffer.doc)
	request_id := pipe.target.request_id
	output_len := pipe.output_len
	if err := process.selection_pipe_apply_explicit(
		pipe,
		&buffer.doc,
		u64(buffer.id),
		buffer.generation,
		request_id,
		item.selection,
	); !errs.ok(err) {
		return err
	}
	item.selection = pipe.transaction.after_selection
	editor_finish_edit(item, previous_revision, {})
	process.selection_pipe_destroy(pipe)
	output_buffer.has_conflict_pipe = false
	log.infof(
		"job: selection conflict applied id=%d window=%d buffer=%d revision=%d bytes=%d",
		request_id,
		u64(item.window_id),
		u64(buffer.id),
		txn.doc_revision(&buffer.doc),
		output_len,
	)
	return {}
}

// The output buffer takes ownership of a fully replayed conflict so the job
// slot can be released without losing the explicit Apply action.
editor_job_preserve_conflict :: proc(state: ^Editor_Job_Output, job: ^process.Job) {
	assert(state != nil && state.buffer != nil && job != nil && job.has_selection_pipe)
	assert(!state.buffer.has_conflict_pipe)
	state.buffer.conflict_pipe = job.selection_pipe
	state.buffer.has_conflict_pipe = true
	job.selection_pipe = {}
	job.has_selection_pipe = false
	editor_refresh_window_tags()
	log.infof(
		"job: selection conflict preserved id=%d window=%d bytes=%d",
		u64(job.id),
		job.attachment,
		state.buffer.conflict_pipe.output_len,
	)
}

editor_job_quit_pending_count :: proc() -> int {
	pending := 0
	for &job in editor.jobs.jobs {
		if job.id != 0 {
			pending += 1
		}
	}
	return pending
}

editor_poll_job_quit :: proc() {
	phase := editor.job_quit.phase
	if phase != .Waiting && phase != .Cancelling {
		return
	}
	if err := lifecycle.job_quit_poll(&editor.job_quit, editor_job_quit_pending_count()); !errs.ok(err) {
		editor_report(err)
		return
	}
	if lifecycle.job_quit_guard_ready(&editor.job_quit) {
		origin := editor.job_quit.origin
		log.infof("job: quit job decisions complete (origin=%v)", origin)
		editor_request_close(.Quit, origin)
	}
}

editor_poll_jobs :: proc() {
	process.job_service_poll(&editor.jobs, mouse_now_ms())
	remaining := JOB_FRAME_OUTPUT_BUDGET
	for offset in 0 ..< process.MAX_JOBS {
		index := (editor.job_output_cursor + offset) % process.MAX_JOBS
		job := &editor.jobs.jobs[index]
		state := &editor.job_outputs[index]
		if job.id == 0 {
			continue
		}
		if job.discard_output {
			editor_job_drain_records(job)
		} else if state.failed_id == job.id {
			editor_job_drain_records(job)
			if job.has_selection_pipe {
				process.selection_pipe_abort(&job.selection_pipe)
			}
			if job.has_regex_search {
				process.regex_search_abort(&job.regex_search)
			}
		} else {
			if state.id != job.id {
				editor_job_output_reset(state)
				if err := editor_job_output_init(state, job); !errs.ok(err) {
					state.failed_id = job.id
					editor_report(err)
					_, stop_err := process.job_stop(&editor.jobs, job.id, mouse_now_ms())
					editor_report(stop_err)
				}
			}
			if state.id == job.id {
				if job.has_regex_search {
					editor_job_poll_regex(job, state, &remaining)
				} else if job.has_selection_pipe {
					pipe := &job.selection_pipe
					if pipe.state == .Collecting && remaining > 0 {
						was_dirty, follow := editor_job_output_snapshot(state)
						consumed, consume_err := process.selection_pipe_consume(pipe, &job.pump, &state.output, remaining)
						remaining -= consumed
						editor_job_output_apply(state, was_dirty, follow)
						if !errs.ok(consume_err) {
							editor_job_queue_error(state, consume_err.message)
							errs.destroy(&consume_err)
							if process.job_active(job) {
								_, stop_err := process.job_stop(&editor.jobs, job.id, mouse_now_ms())
								editor_report(stop_err)
							}
						}
					}
					output_done := process.pump_drained(&job.pump)
					if pipe.state == .Collecting && ((job.state == .Exited && output_done) || job.state == .FailedToStart) {
						if job.state == .Exited && job.exit_status.success && job.err.kind == .None {
							process.selection_pipe_ready(pipe)
						} else {
							process.selection_pipe_abort(pipe)
						}
					}
					if pipe.state == .Ready {
						apply_err := editor_job_apply_selection(job)
						if !errs.ok(apply_err) {
							log.warnf("job: selection apply failed id=%d kind=%v message=%s", u64(job.id), apply_err.kind, apply_err.message)
							editor_job_queue_error(state, apply_err.message)
							errs.destroy(&apply_err)
						}
					}
					if (pipe.state == .Conflict || pipe.state == .Failed) && remaining > 0 && !process.selection_pipe_replay_done(pipe) {
						was_dirty, follow := editor_job_output_snapshot(state)
						replayed, replay_err := process.selection_pipe_replay(pipe, &state.output, remaining)
						remaining -= replayed
						editor_job_output_apply(state, was_dirty, follow)
						if !errs.ok(replay_err) {
							editor_report(replay_err)
							pipe.replay_offset = pipe.output_len
						}
					}
				} else if remaining > 0 {
					was_dirty, follow := editor_job_output_snapshot(state)
					consumed, consume_err := process.output_consume(&state.output, &job.pump, min(remaining, process.DEFAULT_OUTPUT_BATCH_BYTES))
					remaining -= consumed
					editor_job_output_apply(state, was_dirty, follow)
					if !errs.ok(consume_err) {
						editor_job_queue_error(state, consume_err.message)
						errs.destroy(&consume_err)
					}
				}
				editor_job_flush_error(state, &remaining)
			}
		}
		can_release := true
		if process.job_releasable(job) {
			if job.err.kind != .None && !state.error_reported {
				state.error_reported = true
				if state.failed_id == job.id || job.discard_output {
					editor_report(errs.new(job.err.kind, job.err.message, allocator = permanent()))
				} else {
					editor_job_queue_error(state, job.err.message)
				}
			}
			if !job.discard_output && state.failed_id != job.id {
				can_release = editor_job_flush_error(state, &remaining)
				if job.has_selection_pipe {
					pipe := &job.selection_pipe
					if (pipe.state == .Conflict || pipe.state == .Failed) && !process.selection_pipe_replay_done(pipe) {
						can_release = false
					}
				}
			}
			if can_release {
				id := job.id
				if !job.discard_output && state.failed_id != id && job.has_selection_pipe && job.selection_pipe.state == .Conflict {
					editor_job_preserve_conflict(state, job)
				}
				if !job.discard_output && state.failed_id != id {
					was_dirty, follow := editor_job_output_snapshot(state)
					finish_err := process.output_finish(&state.output)
					editor_job_output_apply(state, was_dirty, follow)
					if !errs.ok(finish_err) {
						editor_report(finish_err)
					}
				}
				release_err := process.job_release(&editor.jobs, id)
				editor_report(release_err)
				log.infof("job: released id=%d", u64(id))
				editor_job_output_reset(state)
			}
		}
		editor.job_output_cursor = (index + 1) % process.MAX_JOBS
	}
}

editor_start_flood_test_job :: proc(helper: string) -> errs.Error {
	id, start_err := process.job_start(&editor.jobs, {command = {helper, "flood"}}, nil, u64(editor.active_window))
	if !errs.ok(start_err) {
		return start_err
	}
	job := process.job_find(&editor.jobs, id)
	if job == nil || job.state != .Running {
		return errs.new(.Internal, "job: flood test helper did not start", allocator = permanent())
	}
	log.infof("job: flood test helper started id=%d process=%d", u64(id), u64(job.handle.id))
	return {}
}

editor_start_selection_test_job :: proc(helper: string) -> errs.Error {
	item := editor_active_view()
	buffer := editor_buffer_for_view(item)
	if item == nil || buffer == nil {
		return errs.new(.NotFound, "job: selection test has no source view", allocator = permanent())
	}
	end := rope.tree_byte_count(&buffer.doc.tree)
	item.selection = {anchor = end, active = 0, affinity = .Right}
	helper_mode := "pipe"
	if delay, found := os.lookup_env("HAMMER_TEST_PIPE_DELAY", context.temp_allocator); found && delay == "1" {
		helper_mode = "pipe-delay"
	}
	id, start_err := process.job_start_selection(
		&editor.jobs,
		{command = {helper, helper_mode}},
		&buffer.doc,
		item.selection,
		u64(buffer.id),
		buffer.generation,
		u64(item.window_id),
	)
	if !errs.ok(start_err) {
		return start_err
	}
	job := process.job_find(&editor.jobs, id)
	if job == nil || job.state != .Running {
		return errs.new(.Internal, "job: selection test helper did not start", allocator = permanent())
	}
	log.infof("job: selection test helper started id=%d process=%d bytes=%d", u64(id), u64(job.handle.id), len(job.input))
	return {}
}

// editor_jobs_report renders one line per running job. The result is owned by
// the caller (allocated with context.temp_allocator); free it with delete.
editor_jobs_report :: proc() -> string {
	result := make([dynamic]byte, context.temp_allocator)
	count := 0
	for &job in editor.jobs.jobs {
		if job.id == 0 || !process.job_active(&job) {
			continue
		}
		count += 1
		line := fmt.aprintf(
			"id=%d state=%s command=%s\n",
			u64(job.id),
			process.job_state_name(job.state),
			job.command,
			allocator = context.temp_allocator,
		)
		if line == "" {
			delete(result)
			return ""
		}
		append(&result, ..transmute([]byte)line)
		delete(line, context.temp_allocator)
	}
	if count == 0 {
		line := fmt.aprintf("no running jobs\n", allocator = context.temp_allocator)
		if line == "" {
			delete(result)
			return ""
		}
		append(&result, ..transmute([]byte)line)
		delete(line, context.temp_allocator)
	}
	return string(result[:])
}

// editor_command_jobs opens a +Jobs buffer listing running jobs.
editor_command_jobs :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "job: Jobs takes no arguments", allocator = permanent())
	}
	if editor.workspace.column_count == 0 {
		return errs.new(.NotFound, "job: no column is available for the job list", allocator = permanent())
	}
	report := editor_jobs_report()
	defer delete(report, context.temp_allocator)
	buffer, alloc_err := editor_alloc_buffer_content("", transmute([]byte)report, .Jobs)
	if !errs.ok(alloc_err) {
		return alloc_err
	}
	column_id := editor.workspace.columns[editor.workspace.column_count - 1].id
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		return open_err
	}
	log.infof(
		"job: listed %d running job(s) in window %d",
		process.job_service_active_count(&editor.jobs),
		u64(item.window_id),
	)
	return {}
}

// editor_command_kill stops the running job named by `Kill <id>`, or by the
// button-1 chord selection when no argument is given.
editor_command_kill :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	id_text := strings.trim_space(invocation.argument)
	owned: []byte
	if id_text == "" && cmd_context.argument_chord {
		if selected, ok := editor_command_argument_target(&cmd_context.argument); ok {
			range := editing.selection_range(selected.selection^)
			data, read_err := mouse.read_action_text(selected.doc, range, context.temp_allocator)
			if !errs.ok(read_err) {
				return read_err
			}
			owned = data
			id_text = strings.trim_space(string(data))
		}
	}
	defer if owned != nil {
		delete(owned, context.temp_allocator)
	}
	if id_text == "" {
		return errs.new(.Invalid_Input, "job: Kill requires a numeric job id (Kill <id>)", allocator = permanent())
	}
	id, ok := strconv.parse_u64(id_text, 10)
	if !ok {
		return errs.newf(.Invalid_Input, "job: %q is not a job id", id_text, allocator = permanent())
	}
	stopped, stop_err := process.job_stop(&editor.jobs, process.Job_ID(id), mouse_now_ms())
	if !errs.ok(stop_err) {
		return stop_err
	}
	if !stopped {
		return errs.newf(.NotFound, "job: no running job with id %d", id, allocator = permanent())
	}
	log.infof("job: Kill requested for id=%d", id)
	return {}
}
