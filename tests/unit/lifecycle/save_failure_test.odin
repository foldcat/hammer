package lifecycle_test

import "core:testing"

import errs "hammer:core/errs"
import lifecycle "hammer:core/lifecycle"

save_failure_begin :: proc(t: ^testing.T, guard: ^lifecycle.Close_Guard, buffers: []lifecycle.Buffer_Snapshot) {
	close_expect_ok(t, lifecycle.close_request(guard, close_quit(.Keyboard), buffers))
	close_expect_ok(t, lifecycle.close_decision(guard, .Save_All))
	testing.expect(t, guard.phase == .Saving)
}

@(test)
test_save_failure_blocks_then_retries :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffer := close_buffer(4, 6, 1, true)
	save_failure_begin(t, &guard, {buffer})

	cause := errs.new(.IO, "disk full")
	close_expect_ok(t, lifecycle.close_save_failed(
		&guard,
		buffer.id,
		buffer.generation,
		buffer.revision,
		buffer.revision,
		cause,
		false,
	)) // cause ownership transferred; do not destroy it here
	testing.expect(t, guard.phase == .Save_Failed)
	testing.expect(t, !lifecycle.close_guard_ready(&guard))
	close_expect_kind(t, lifecycle.close_finish(&guard), .Conflict)
	pending := lifecycle.close_pending(&guard)
	testing.expect(t, len(pending) == 1 && pending[0].resolution == .Failed)
	failure, ok := lifecycle.close_failure(&guard)
	testing.expect(t, ok && failure.buffer_id == buffer.id)
	testing.expect(t, failure.kind == .Operation_Failed && !failure.replaced)
	testing.expect(t, failure.cause.kind == .IO && failure.cause.message == "disk full")
	current, current_ok := lifecycle.close_current(&guard)
	testing.expect(t, current_ok && current.id == buffer.id)

	close_expect_ok(t, lifecycle.close_decision(&guard, .Retry_Save))
	testing.expect(t, guard.phase == .Saving)
	_, failure_ok := lifecycle.close_failure(&guard)
	testing.expect(t, !failure_ok)
	testing.expect(t, lifecycle.close_pending(&guard)[0].resolution == .Unresolved)
	close_expect_ok(t, lifecycle.close_save_succeeded(
		&guard,
		buffer.id,
		buffer.generation,
		buffer.revision,
		buffer.revision,
	))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_save_failure_stale_result_keeps_ownership :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffer := close_buffer(5, 9, 1, true)
	save_failure_begin(t, &guard, {buffer})

	stale := errs.new(.IO, "stale failure")
	close_expect_kind(t, lifecycle.close_save_failed(
		&guard,
		buffer.id,
		buffer.generation,
		buffer.revision + 1,
		buffer.revision,
		stale,
		false,
	), .Conflict)
	errs.destroy(&stale) // rejected failure remains caller-owned
	testing.expect(t, guard.phase == .Saving)
	_, failed := lifecycle.close_failure(&guard)
	testing.expect(t, !failed)
	testing.expect(t, lifecycle.close_pending(&guard)[0].resolution == .Unresolved)

	close_expect_kind(t, lifecycle.close_save_failed(
		&guard,
		buffer.id,
		buffer.generation,
		buffer.revision,
		buffer.revision,
		{},
		false,
	), .Invalid_Input)
	close_expect_kind(t, lifecycle.close_save_as_canceled(&guard, buffer.id, buffer.generation, buffer.revision + 1, buffer.revision), .Conflict)
	testing.expect(t, guard.phase == .Saving)
}

@(test)
test_save_as_cancellation_blocks_and_can_restart :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	untitled := close_buffer(8, 2, 1, true)
	save_failure_begin(t, &guard, {untitled})
	close_expect_ok(t, lifecycle.close_save_as_canceled(
		&guard,
		untitled.id,
		untitled.generation,
		untitled.revision,
		untitled.revision,
	))
	testing.expect(t, guard.phase == .Save_Failed)
	close_expect_kind(t, lifecycle.close_finish(&guard), .Conflict)
	close_expect_kind(t, lifecycle.close_decision(&guard, .Retry_Save), .Conflict)
	failure, ok := lifecycle.close_failure(&guard)
	testing.expect(t, ok && failure.kind == .Save_As_Canceled && !failure.replaced)
	testing.expect(t, errs.ok(failure.cause))

	close_expect_ok(t, lifecycle.close_decision(&guard, .Save_As))
	testing.expect(t, guard.phase == .Saving)
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, 8, 108, 2, 2))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_post_publication_failure_requires_deliberate_action :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffer := close_buffer(11, 3, 1, true)
	save_failure_begin(t, &guard, {buffer})
	cause := errs.new(.IO, "post-rename checkpoint capture failed")
	close_expect_ok(t, lifecycle.close_save_failed(
		&guard,
		buffer.id,
		buffer.generation,
		buffer.revision,
		buffer.revision,
		cause,
		true,
	))
	close_expect_kind(t, lifecycle.close_decision(&guard, .Retry_Save), .Conflict)
	close_expect_kind(t, lifecycle.close_decision(&guard, .Review_Unsaved), .Conflict)
	close_expect_kind(t, lifecycle.close_finish(&guard), .Conflict)
	failure, ok := lifecycle.close_failure(&guard)
	testing.expect(t, ok && failure.replaced && failure.cause.message == "post-rename checkpoint capture failed")
	testing.expect(t, guard.phase == .Save_Failed)

	close_expect_ok(t, lifecycle.close_decision(&guard, .Save_As))
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, 11, 111, 3, 3))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_save_failure_review_discard_and_cancel :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	first := close_buffer(1, 1, 1, true)
	second := close_buffer(2, 2, 1, true)
	buffers := []lifecycle.Buffer_Snapshot {first, second}
	save_failure_begin(t, &guard, buffers)
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, 1, 101, 1, 1))
	first_cause := errs.new(.IO, "permission denied")
	close_expect_ok(t, lifecycle.close_save_failed(&guard, 2, 102, 2, 2, first_cause, false))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_Current))
	testing.expect(t, guard.phase == .Ready)
	pending := lifecycle.close_pending(&guard)
	testing.expect(t, pending[0].resolution == .Saved && pending[1].resolution == .Discarded)
	close_expect_ok(t, lifecycle.close_finish(&guard))

	save_failure_begin(t, &guard, buffers)
	second_cause := errs.new(.IO, "rename failed")
	close_expect_ok(t, lifecycle.close_save_failed(&guard, 1, 101, 1, 1, second_cause, false))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Review_Unsaved))
	testing.expect(t, guard.phase == .Reviewing && guard.next == 0)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_Current))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_Current))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))

	save_failure_begin(t, &guard, buffers)
	third_cause := errs.new(.IO, "canceled by test")
	close_expect_ok(t, lifecycle.close_save_failed(&guard, 1, 101, 1, 1, third_cause, false))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
	testing.expect(t, guard.phase == .Idle)
	_, failed := lifecycle.close_failure(&guard)
	testing.expect(t, !failed)
	close_expect_kind(t, lifecycle.close_save_succeeded(&guard, 1, 101, 1, 1), .Conflict)
}

@(test)
test_save_failure_discard_all_and_destroy :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	first := close_buffer(1, 1, 1, true)
	second := close_buffer(2, 2, 1, true)
	save_failure_begin(t, &guard, {first, second})
	cause := errs.new(.IO, "sync failed")
	close_expect_ok(t, lifecycle.close_save_failed(&guard, 1, 101, 1, 1, cause, false))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_All))
	testing.expect(t, guard.phase == .Ready)
	for buffer in lifecycle.close_pending(&guard) {
		testing.expect(t, buffer.resolution == .Discarded)
	}
	close_expect_ok(t, lifecycle.close_finish(&guard))
	lifecycle.close_guard_destroy(&guard)

	active: lifecycle.Close_Guard
	close_init(t, &active)
	buffer := close_buffer(9, 4, 1, true)
	save_failure_begin(t, &active, {buffer})
	active_cause := errs.new(.IO, "active failure")
	close_expect_ok(t, lifecycle.close_save_failed(&active, 9, 109, 4, 4, active_cause, false))
	testing.expect(t, active.phase == .Save_Failed)
	lifecycle.close_guard_destroy(&active)
	testing.expect(t, !active.initialized && errs.ok(active.failure.cause))
}
