package lifecycle_test

import "core:testing"

import errs "hammer:core/errs"
import lifecycle "hammer:core/lifecycle"

@(test)
test_full_lifecycle :: proc(t: ^testing.T) {
	a: lifecycle.App
	defer lifecycle.app_destroy(&a)

	testing.expect(t, a.phase == .Uninitialized)
	testing.expect(t, a.quit_reason == .None)

	lifecycle.app_enter_initializing(&a)
	testing.expect(t, a.phase == .Initializing)

	lifecycle.app_enter_running(&a)
	testing.expect(t, a.phase == .Running)
	testing.expect(t, !lifecycle.app_is_quitting(&a))

	lifecycle.app_request_quit(&a, .User_Request)
	testing.expect(t, a.phase == .Quitting)
	testing.expect(t, a.quit_reason == .User_Request)
	testing.expect(t, lifecycle.app_is_quitting(&a))

	// Repeated requests are no-ops; the first reason wins.
	lifecycle.app_request_quit(&a, .Autoquit)
	testing.expect(t, a.quit_reason == .User_Request)

	lifecycle.app_enter_shutdown(&a)
	testing.expect(t, a.phase == .Shutdown)

	lifecycle.app_enter_exited(&a)
	testing.expect(t, a.phase == .Exited)
}

@(test)
test_cancel_user_quit :: proc(t: ^testing.T) {
	a: lifecycle.App
	defer lifecycle.app_destroy(&a)

	lifecycle.app_enter_initializing(&a)
	lifecycle.app_enter_running(&a)
	lifecycle.app_request_quit(&a, .User_Request)
	lifecycle.app_cancel_quit(&a)

	testing.expect(t, a.phase == .Running)
	testing.expect(t, a.quit_reason == .None)
	testing.expect(t, !lifecycle.app_is_quitting(&a))

	// A quit can be requested again after a cancel.
	lifecycle.app_request_quit(&a, .User_Request)
	testing.expect(t, a.phase == .Quitting)
}

@(test)
test_quit_from_initializing_takes_error :: proc(t: ^testing.T) {
	a: lifecycle.App
	defer lifecycle.app_destroy(&a)

	lifecycle.app_enter_initializing(&a)
	e := errs.new(.Internal, "gfx setup failed")
	lifecycle.app_request_quit(&a, .Init_Failed, e) // ownership transfers here

	testing.expect(t, a.phase == .Quitting)
	testing.expect(t, a.quit_reason == .Init_Failed)
	testing.expect(t, a.fatal_error.kind == .Internal)
	testing.expect(t, a.fatal_error.message == "gfx setup failed")

	// Fatal quits cannot be cancelled; shutdown proceeds normally.
	lifecycle.app_enter_shutdown(&a)
	lifecycle.app_enter_exited(&a)
}

@(test)
test_fatal_error_survives_shutdown_until_destroy :: proc(t: ^testing.T) {
	a: lifecycle.App
	lifecycle.app_enter_initializing(&a)
	lifecycle.app_enter_running(&a)
	e := errs.newf(.IO, "disk %d", 5)
	lifecycle.app_request_quit(&a, .Fatal_Error, e)
	lifecycle.app_enter_shutdown(&a)
	lifecycle.app_enter_exited(&a)

	testing.expect(t, a.fatal_error.kind == .IO)
	testing.expect(t, a.fatal_error.message == "disk 5")

	lifecycle.app_destroy(&a)
	testing.expect(t, a.phase == .Uninitialized) // reset to zero
	testing.expect(t, errs.ok(a.fatal_error))
}

@(test)
test_destroy_zero_app_is_safe :: proc(t: ^testing.T) {
	a: lifecycle.App
	lifecycle.app_destroy(&a) // must be a no-op on the zero value
	testing.expect(t, a.phase == .Uninitialized)
}
