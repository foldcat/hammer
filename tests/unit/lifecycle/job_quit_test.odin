package lifecycle_test

import "core:testing"

import lifecycle "hammer:core/lifecycle"

@(test)
test_job_quit_all_origins_can_cancel_exit :: proc(t: ^testing.T) {
	guard: lifecycle.Job_Quit_Guard
	close_expect_ok(t, lifecycle.job_quit_guard_init(&guard, context.allocator))
	defer lifecycle.job_quit_guard_destroy(&guard)
	origins := []lifecycle.Close_Origin{.Keyboard, .Mouse, .Tag_Command, .OS_Close, .IPC, .Filesystem}
	for origin in origins {
		close_expect_ok(t, lifecycle.job_quit_request(&guard, origin, 2))
		testing.expect(t, guard.phase == .Await_Decision && guard.origin == origin)
		testing.expect(t, lifecycle.job_quit_guard_active(&guard) && !lifecycle.job_quit_guard_ready(&guard))
		close_expect_kind(t, lifecycle.job_quit_poll(&guard, 0), .Conflict)
		close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Cancel_Exit))
		testing.expect(t, guard.phase == .Idle && !lifecycle.job_quit_guard_active(&guard))
	}
}

@(test)
test_job_quit_wait_requires_pending_completion :: proc(t: ^testing.T) {
	guard: lifecycle.Job_Quit_Guard
	close_expect_ok(t, lifecycle.job_quit_guard_init(&guard, context.allocator))
	defer lifecycle.job_quit_guard_destroy(&guard)
	close_expect_ok(t, lifecycle.job_quit_request(&guard, .Keyboard, 1))
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Wait))
	close_expect_kind(t, lifecycle.job_quit_decision(&guard, .Wait), .Conflict)
	close_expect_ok(t, lifecycle.job_quit_poll(&guard, 1))
	testing.expect(t, guard.phase == .Waiting && !lifecycle.job_quit_guard_ready(&guard))
	close_expect_ok(t, lifecycle.job_quit_poll(&guard, 0))
	testing.expect(t, guard.phase == .Ready && lifecycle.job_quit_guard_ready(&guard))
	close_expect_kind(t, lifecycle.job_quit_decision(&guard, .Cancel_Exit), .Conflict)
	lifecycle.job_quit_guard_reset(&guard)
	close_expect_ok(t, lifecycle.job_quit_request(&guard, .OS_Close, 0))
	testing.expect(t, lifecycle.job_quit_guard_ready(&guard))
}

@(test)
test_job_quit_cancel_jobs_waits_and_can_still_cancel_exit :: proc(t: ^testing.T) {
	guard: lifecycle.Job_Quit_Guard
	close_expect_ok(t, lifecycle.job_quit_guard_init(&guard, context.allocator))
	defer lifecycle.job_quit_guard_destroy(&guard)
	close_expect_ok(t, lifecycle.job_quit_request(&guard, .Tag_Command, 3))
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Wait))
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Cancel_Jobs))
	testing.expect(t, guard.phase == .Cancelling)
	close_expect_kind(t, lifecycle.job_quit_decision(&guard, .Cancel_Jobs), .Conflict)
	close_expect_ok(t, lifecycle.job_quit_poll(&guard, 2))
	testing.expect(t, guard.phase == .Cancelling)
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Cancel_Exit))
	testing.expect(t, guard.phase == .Idle)

	close_expect_ok(t, lifecycle.job_quit_request(&guard, .Tag_Command, 1))
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Cancel_Jobs))
	close_expect_ok(t, lifecycle.job_quit_poll(&guard, 0))
	testing.expect(t, lifecycle.job_quit_guard_ready(&guard))
}

@(test)
test_job_quit_validation_and_reuse :: proc(t: ^testing.T) {
	uninitialized: lifecycle.Job_Quit_Guard
	close_expect_kind(t, lifecycle.job_quit_request(&uninitialized, .Keyboard, 0), .Invalid_Input)
	lifecycle.job_quit_guard_destroy(&uninitialized)

	guard: lifecycle.Job_Quit_Guard
	close_expect_ok(t, lifecycle.job_quit_guard_init(&guard, context.allocator))
	defer lifecycle.job_quit_guard_destroy(&guard)
	close_expect_kind(t, lifecycle.job_quit_request(&guard, lifecycle.Close_Origin(99), 1), .Invalid_Input)
	close_expect_kind(t, lifecycle.job_quit_request(&guard, .Keyboard, -1), .Invalid_Input)
	close_expect_ok(t, lifecycle.job_quit_request(&guard, .Keyboard, 1))
	close_expect_kind(t, lifecycle.job_quit_request(&guard, .Keyboard, 1), .Conflict)
	close_expect_kind(t, lifecycle.job_quit_decision(&guard, lifecycle.Job_Quit_Decision(99)), .Invalid_Input)
	close_expect_ok(t, lifecycle.job_quit_decision(&guard, .Cancel_Exit))
	close_expect_kind(t, lifecycle.job_quit_decision(&guard, .Cancel_Exit), .Conflict)
	close_expect_kind(t, lifecycle.job_quit_poll(&guard, -1), .Conflict)
}
