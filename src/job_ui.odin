package main

import "core:fmt"
import "core:log"

import errs "core/errs"
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

editor_job_output_init :: proc(state: ^Editor_Job_Output, job: ^process.Job) -> errs.Error {
	if editor.workspace.column_count == 0 {
		return errs.new(.NotFound, "job: no column is available for output", allocator = permanent())
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
	column_id := editor.workspace.columns[editor.workspace.column_count - 1].id
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		process.output_destroy(&output)
		return open_err
	}
	state^ = {id = job.id, buffer = buffer, output = output}
	job.attachment = u64(item.window_id)
	log.infof("job: output opened id=%d window=%d buffer=%d", u64(job.id), u64(item.window_id), u64(buffer.id))
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
		if state.failed_id == job.id {
			for {
				_, ok := process.pump_next(&job.pump)
				if !ok {
					break
				}
				process.pump_release(&job.pump)
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
			if state.id == job.id && remaining > 0 {
				was_dirty, follow := editor_job_output_snapshot(state)
				consumed, consume_err := process.output_consume(&state.output, &job.pump, min(remaining, process.DEFAULT_OUTPUT_BATCH_BYTES))
				remaining -= consumed
				editor_job_output_apply(state, was_dirty, follow)
				if !errs.ok(consume_err) {
					editor_job_queue_error(state, consume_err.message)
					errs.destroy(&consume_err)
				}
				editor_job_flush_error(state, &remaining)
			}
		}
		can_release := true
		if process.job_releasable(job) {
			if job.err.kind != .None && !state.error_reported {
				state.error_reported = true
				if state.failed_id == job.id {
					editor_report(errs.new(job.err.kind, job.err.message, allocator = permanent()))
				} else {
					editor_job_queue_error(state, job.err.message)
				}
			}
			if state.failed_id != job.id {
				can_release = editor_job_flush_error(state, &remaining)
			}
			if can_release {
				id := job.id
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
