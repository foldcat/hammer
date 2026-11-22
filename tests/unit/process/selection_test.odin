package process_test

import "core:strings"
import "core:testing"
import "core:time"

import errs "hammer:core/errs"
import process "hammer:core/process"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

selection_test_text :: proc(t: ^testing.T, doc: ^txn.Doc) -> []byte {
	content, err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	expect_ok(t, err)
	return content
}

selection_test_edit :: proc(t: ^testing.T, doc: ^txn.Doc, op: txn.Operation) {
	edit := txn.Transaction{
		source = .Typing,
		base_revision = txn.doc_revision(doc),
		ops = []txn.Operation{op},
	}
	expect_ok(t, txn.doc_apply(doc, &edit, context.allocator))
}

drive_selection_job :: proc(t: ^testing.T, service: ^process.Job_Service, id: process.Job_ID, diagnostics: ^process.Output_Buffer) -> errs.Error {
	for iteration in 0 ..< 10000 {
		process.job_service_poll(service, u64(iteration))
		job := process.job_find(service, id)
		if job == nil {
			return errs.new(.Internal, "selection test job disappeared", allocator = context.allocator)
		}
		pipe := &job.selection_pipe
		if pipe.state == .Collecting {
			_, consume_err := process.selection_pipe_consume(pipe, &job.pump, diagnostics, 7)
			if !errs.ok(consume_err) {
				return consume_err
			}
		}
		if pipe.state == .Collecting && job.state == .Exited && process.pump_drained(&job.pump) {
			if job.exit_status.success && job.err.kind == .None {
				process.selection_pipe_ready(pipe)
			} else {
				process.selection_pipe_abort(pipe)
			}
		}
		if pipe.state != .Collecting && process.pump_drained(&job.pump) {
			return {}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "selection job did not finish within the polling budget")
	return {}
}

@(test)
test_selection_pipe_replaces_stdin_snapshot_in_one_undo_transaction :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("alpha β\n"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	diagnostics_doc: txn.Doc
	expect_ok(t, txn.doc_init(&diagnostics_doc, {}, context.allocator))
	defer txn.doc_destroy(&diagnostics_doc)
	diagnostics: process.Output_Buffer
	expect_ok(t, process.output_init(&diagnostics, &diagnostics_doc, {batch_bytes = 8, scrollback_bytes = 128}, context.allocator))
	defer process.output_destroy(&diagnostics)
	service: process.Job_Service
	process.job_service_init(&service, {pump = {record_capacity = 4, chunk_bytes = 5}}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	selection := txn.Selection{anchor = rope.tree_byte_count(&source.tree), active = 0, affinity = .Right}
	id, start_err := process.job_start_selection(&service, {command = {HELPER, "pipe"}}, &source, selection, 11, 12, 13)
	expect_ok(t, start_err)
	selection = {}
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.has_selection_pipe && string(job.input) == "alpha β\n")
	expect_ok(t, drive_selection_job(t, &service, id, &diagnostics))
	testing.expect(t, job.selection_pipe.state == .Ready)
	expect_ok(t, process.selection_pipe_apply(&job.selection_pipe, &source, 11, 12, u64(id)))
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expectf(t, string(content) == "filtered:alpha β\n", "replacement %q", string(content))
	testing.expect(t, job.selection_pipe.state == .Applied && job.selection_pipe.has_update)
	testing.expect(t, job.selection_pipe.transaction.after_selection.anchor == len(content))
	testing.expect(t, job.selection_pipe.transaction.after_selection.active == 0)
	testing.expect(t, txn.doc_log_len(&source) == 1 && source.log[0].source == .Command_Output)
	diagnostic_content := selection_test_text(t, &diagnostics_doc)
	defer delete(diagnostic_content, context.allocator)
	testing.expect(t, string(diagnostic_content) == "pipe diagnostic\n")
	_, undo_err := txn.doc_undo(&source)
	expect_ok(t, undo_err)
	original := selection_test_text(t, &source)
	defer delete(original, context.allocator)
	testing.expect(t, string(original) == "alpha β\n")
	expect_ok(t, process.job_release(&service, id))
}

@(test)
test_selection_pipe_transforms_nonoverlapping_edits :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("alpha beta gamma"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	pipe: process.Selection_Pipe
	expect_ok(t, process.selection_pipe_init(&pipe, &source, {anchor = 6, active = 10}, 15, 16, 17, {output_bytes = 32}, context.allocator))
	defer process.selection_pipe_destroy(&pipe)
	copy(pipe.output, "filtered:beta")
	pipe.output_len = len("filtered:beta")
	process.selection_pipe_ready(&pipe)
	selection_test_edit(t, &source, txn.Insert{pos = 0, data = transmute([]byte)string(">")})
	selection_test_edit(t, &source, txn.Insert{pos = rope.tree_byte_count(&source.tree), data = transmute([]byte)string("!")})
	expect_ok(t, process.selection_pipe_apply(&pipe, &source, 15, 16, 17))
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expectf(t, string(content) == ">alpha filtered:beta gamma!", "replacement %q", string(content))
	_, undo_err := txn.doc_undo(&source)
	expect_ok(t, undo_err)
	original := selection_test_text(t, &source)
	defer delete(original, context.allocator)
	testing.expect(t, string(original) == ">alpha beta gamma!")
}

@(test)
test_selection_pipe_preserves_insertions_at_range_boundaries :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("alpha"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	pipe: process.Selection_Pipe
	expect_ok(t, process.selection_pipe_init(&pipe, &source, {anchor = 1, active = 4}, 18, 19, 20, {output_bytes = 8}, context.allocator))
	defer process.selection_pipe_destroy(&pipe)
	pipe.output[0] = 'X'
	pipe.output_len = 1
	process.selection_pipe_ready(&pipe)
	selection_test_edit(t, &source, txn.Insert{pos = 1, data = transmute([]byte)string("<")})
	selection_test_edit(t, &source, txn.Insert{pos = 5, data = transmute([]byte)string(">")})
	expect_ok(t, process.selection_pipe_apply(&pipe, &source, 18, 19, 20))
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expectf(t, string(content) == "a<X>a", "replacement %q", string(content))
}

@(test)
test_selection_pipe_empty_target_conflicts_at_edit_position :: proc(t: ^testing.T) {
	operations := []txn.Operation{
		txn.Insert{pos = 1, data = transmute([]byte)string("q")},
		txn.Replace{range = {1, 2}, data = transmute([]byte)string("q")},
	}
	for op in operations {
		source: txn.Doc
		expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("abc"), {}, context.allocator))
		pipe: process.Selection_Pipe
		expect_ok(t, process.selection_pipe_init(&pipe, &source, {anchor = 1, active = 1}, 18, 19, 20, {output_bytes = 8}, context.allocator))
		pipe.output[0] = 'X'
		pipe.output_len = 1
		process.selection_pipe_ready(&pipe)
		selection_test_edit(t, &source, op)
		apply_err := process.selection_pipe_apply(&pipe, &source, 18, 19, 20)
		expect_kind(t, apply_err, .Conflict)
		testing.expect(t, pipe.state == .Conflict && txn.doc_revision(&source) == 1)
		process.selection_pipe_destroy(&pipe)
		txn.doc_destroy(&source)
	}
}

@(test)
test_selection_pipe_rejects_abandoned_history_branch :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("abc"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	selection_test_edit(t, &source, txn.Insert{pos = 0, data = transmute([]byte)string("x")})
	pipe: process.Selection_Pipe
	expect_ok(t, process.selection_pipe_init(&pipe, &source, {anchor = 0, active = 4}, 18, 19, 20, {output_bytes = 8}, context.allocator))
	defer process.selection_pipe_destroy(&pipe)
	pipe.output[0] = 'Y'
	pipe.output_len = 1
	process.selection_pipe_ready(&pipe)
	_, undo_err := txn.doc_undo(&source)
	expect_ok(t, undo_err)
	selection_test_edit(t, &source, txn.Insert{pos = 0, data = transmute([]byte)string("z")})
	apply_err := process.selection_pipe_apply(&pipe, &source, 18, 19, 20)
	expect_kind(t, apply_err, .Conflict)
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expect(t, string(content) == "zabc")
}

@(test)
test_selection_pipe_rejects_overlap_and_applies_explicitly :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("alpha"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	diagnostics_doc: txn.Doc
	expect_ok(t, txn.doc_init(&diagnostics_doc, {}, context.allocator))
	defer txn.doc_destroy(&diagnostics_doc)
	diagnostics: process.Output_Buffer
	expect_ok(t, process.output_init(&diagnostics, &diagnostics_doc, {}, context.allocator))
	defer process.output_destroy(&diagnostics)
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	selection := txn.Selection{anchor = 0, active = 5, affinity = .Right}
	id, start_err := process.job_start_selection(&service, {command = {HELPER, "pipe"}}, &source, selection, 21, 22, 23)
	expect_ok(t, start_err)
	edit := txn.Transaction{
		source = .Typing,
		base_revision = txn.doc_revision(&source),
		ops = []txn.Operation{txn.Insert{pos = 2, data = transmute([]byte)string("!")}},
		after_selection = {anchor = 6, active = 6, affinity = .Right},
	}
	expect_ok(t, txn.doc_apply(&source, &edit, context.allocator))
	expect_ok(t, drive_selection_job(t, &service, id, &diagnostics))
	job := process.job_find(&service, id)
	apply_err := process.selection_pipe_apply(&job.selection_pipe, &source, 21, 22, u64(id))
	expect_kind(t, apply_err, .Conflict)
	testing.expect(t, job.selection_pipe.state == .Conflict)
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expect(t, string(content) == "al!pha")
	for !process.selection_pipe_replay_done(&job.selection_pipe) {
		_, replay_err := process.selection_pipe_replay(&job.selection_pipe, &diagnostics, 3)
		expect_ok(t, replay_err)
	}
	expect_ok(t, process.output_finish(&diagnostics))
	preserved := selection_test_text(t, &diagnostics_doc)
	defer delete(preserved, context.allocator)
	testing.expect(t, strings.contains(string(preserved), "pipe diagnostic\n"))
	testing.expect(t, strings.contains(string(preserved), "filtered:alpha"))
	invalid_err := process.selection_pipe_apply_explicit(&job.selection_pipe, &source, 21, 22, u64(id), {anchor = 0, active = 7})
	expect_kind(t, invalid_err, .Invalid_Input)
	testing.expect(t, job.selection_pipe.state == .Conflict && txn.doc_revision(&source) == 1)
	expect_ok(t, process.selection_pipe_apply_explicit(&job.selection_pipe, &source, 21, 22, u64(id), {anchor = 3, active = 6}))
	applied := selection_test_text(t, &source)
	defer delete(applied, context.allocator)
	testing.expectf(t, string(applied) == "al!filtered:alpha", "explicit replacement %q", string(applied))
	testing.expect(t, job.selection_pipe.state == .Applied && job.selection_pipe.has_update)
	_, undo_err := txn.doc_undo(&source)
	expect_ok(t, undo_err)
	before_apply := selection_test_text(t, &source)
	defer delete(before_apply, context.allocator)
	testing.expect(t, string(before_apply) == "al!pha")
	expect_ok(t, process.job_release(&service, id))
}

@(test)
test_selection_pipe_output_limit_cancels_without_partial_replacement :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("abcdefgh"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	diagnostics_doc: txn.Doc
	expect_ok(t, txn.doc_init(&diagnostics_doc, {}, context.allocator))
	defer txn.doc_destroy(&diagnostics_doc)
	diagnostics: process.Output_Buffer
	expect_ok(t, process.output_init(&diagnostics, &diagnostics_doc, {}, context.allocator))
	defer process.output_destroy(&diagnostics)
	service: process.Job_Service
	process.job_service_init(&service, {stop_grace_ms = 1, pump = {record_capacity = 2, chunk_bytes = 3}}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	selection := txn.Selection{anchor = 0, active = 8, affinity = .Right}
	id, start_err := process.job_start_selection(
		&service,
		{command = {HELPER, "pipe"}},
		&source,
		selection,
		31,
		32,
		33,
		{output_bytes = 4},
	)
	expect_ok(t, start_err)
	limit_err := drive_selection_job(t, &service, id, &diagnostics)
	expect_kind(t, limit_err, .Resource_Limit)
	job := process.job_find(&service, id)
	testing.expect(t, job.selection_pipe.state == .Failed && job.selection_pipe.output_len > 0 && job.selection_pipe.output_len <= 4)
	_, stop_err := process.job_stop(&service, id, 100)
	expect_ok(t, stop_err)
	for iteration in 0 ..< 10000 {
		process.job_service_poll(&service, u64(iteration + 101))
		for {
			_, ok := process.pump_next(&job.pump)
			if !ok {
				break
			}
			process.pump_release(&job.pump)
		}
		if process.job_releasable(job) {
			break
		}
		testing.expect(t, iteration < 9999, "overflowed selection job did not stop")
		time.sleep(time.Millisecond)
	}
	testing.expect(t, txn.doc_revision(&source) == 0 && job.selection_pipe.state == .Failed)
	expect_ok(t, process.job_release(&service, id))
}

@(test)
test_selection_pipe_validates_identity_selection_and_budget :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&doc, transmute([]byte)string("abc"), {}, context.allocator))
	defer txn.doc_destroy(&doc)
	invalid := txn.Selection{anchor = 0, active = 4}
	pipe: process.Selection_Pipe
	invalid_err := process.selection_pipe_init(&pipe, &doc, invalid, 1, 1, 1, {}, context.allocator)
	expect_kind(t, invalid_err, .Invalid_Input)
	budget_err := process.selection_pipe_init(&pipe, &doc, {}, 1, 1, 1, {output_bytes = process.MAX_SELECTION_OUTPUT_BYTES + 1}, context.allocator)
	expect_kind(t, budget_err, .Resource_Limit)
	expect_ok(t, process.selection_pipe_init(&pipe, &doc, {anchor = 0, active = 3}, 41, 42, 43, {output_bytes = 8}, context.allocator))
	defer process.selection_pipe_destroy(&pipe)
	process.selection_pipe_ready(&pipe)
	identity_err := process.selection_pipe_apply(&pipe, &doc, 41, 42, 99)
	expect_kind(t, identity_err, .Conflict)
	testing.expect(t, txn.doc_revision(&doc) == 0 && pipe.state == .Conflict)
}

@(test)
test_selection_pipe_empty_input_replaces_without_stdin :: proc(t: ^testing.T) {
	source: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&source, transmute([]byte)string("alpha beta\n"), {}, context.allocator))
	defer txn.doc_destroy(&source)
	diagnostics_doc: txn.Doc
	expect_ok(t, txn.doc_init(&diagnostics_doc, {}, context.allocator))
	defer txn.doc_destroy(&diagnostics_doc)
	diagnostics: process.Output_Buffer
	expect_ok(t, process.output_init(&diagnostics, &diagnostics_doc, {batch_bytes = 8, scrollback_bytes = 128}, context.allocator))
	defer process.output_destroy(&diagnostics)
	service: process.Job_Service
	process.job_service_init(&service, {pump = {record_capacity = 4, chunk_bytes = 5}}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	selection := txn.Selection{anchor = 0, active = 11, affinity = .Right}
	id, start_err := process.job_start_selection(&service, {command = {HELPER, "echo"}}, &source, selection, 51, 52, 53, {empty_input = true})
	expect_ok(t, start_err)
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.has_selection_pipe && len(job.input) == 0)
	expect_ok(t, drive_selection_job(t, &service, id, &diagnostics))
	testing.expect(t, job.selection_pipe.state == .Ready)
	expect_ok(t, process.selection_pipe_apply(&job.selection_pipe, &source, 51, 52, u64(id)))
	content := selection_test_text(t, &source)
	defer delete(content, context.allocator)
	testing.expectf(t, string(content) == "stdout=\n", "replacement %q", string(content))
	expect_ok(t, process.job_release(&service, id))
}

@(test)
test_selection_pipe_raku_input_uses_selection_or_whole_buffer :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init_from_bytes(&doc, transmute([]byte)string("abcdef"), {}, context.allocator))
	defer txn.doc_destroy(&doc)

	caret: process.Selection_Pipe
	expect_ok(t, process.selection_pipe_init(
		&caret,
		&doc,
		{anchor = 2, active = 2},
		51,
		52,
		53,
		{whole_buffer_input_when_empty = true},
		context.allocator,
	))
	testing.expect(t, string(caret.input) == "abcdef")
	testing.expect(t, caret.target.range.start == 2 && caret.target.range.end == 2)
	process.selection_pipe_destroy(&caret)

	selection: process.Selection_Pipe
	expect_ok(t, process.selection_pipe_init(
		&selection,
		&doc,
		{anchor = 1, active = 4},
		51,
		52,
		53,
		{whole_buffer_input_when_empty = true},
		context.allocator,
	))
	defer process.selection_pipe_destroy(&selection)
	testing.expect(t, string(selection.input) == "bcd")
	testing.expect(t, selection.target.range.start == 1 && selection.target.range.end == 4)
}
