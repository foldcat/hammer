// Package lifecycle: the application lifecycle state machine.
//
// This is the skeleton the SPECS.md §11.6 shutdown state machine builds
// on. M01.01 implements the transitions and the fatal-error plumbing;
// the dirty-buffer and running-job review stages (M04.06/M04.07/M09.08)
// plug in as decision points inside the Quitting phase without changing
// this shape.
//
// Transitions are programmer invariants: calling a transition from the
// wrong phase is a bug and asserts. `request_quit` is deliberately
// idempotent — repeated quit requests are expected (keyboard, window
// close, autoquit test hook, and later IPC all race through one door).
//
// Ownership: `request_quit` takes ownership of the passed `err` on
// success only (it is required for `.Init_Failed`/`.Fatal_Error` and
// ignored otherwise). The app owns the message inside `fatal_error`
// until `app_destroy`; never destroy the caller's copy after a
// successful request.
package lifecycle

import errs "../errs"

Phase :: enum {
	Uninitialized, // zero value; nothing has run yet
	Initializing, // window/GL/services being set up
	Running, // main loop active
	Quitting, // quit requested; draining (M04 adds the review stage here)
	Shutdown, // cleanup complete; about to leave the main loop
	Exited, // terminal; main() is returning
}

Quit_Reason :: enum {
	None, // no quit requested
	User_Request, // explicit user quit (key, window close, later IPC)
	Autoquit, // test hook / scripted quit (HAMMER_AUTOQUIT_FRAMES)
	Init_Failed, // a fatal error during initialization
	Fatal_Error, // a fatal error at runtime
}

App :: struct {
	phase: Phase,
	quit_reason: Quit_Reason,
	// fatal_error is owned by the App; meaningful when quit_reason is
	// .Init_Failed or .Fatal_Error. Released by `app_destroy`.
	fatal_error: errs.Error,
}

// app_enter_initializing moves Uninitialized -> Initializing. Call it
// once, before any backend setup.
app_enter_initializing :: proc(a: ^App) {
	assert(a.phase == .Uninitialized, "lifecycle: enter_initializing from non-Uninitialized phase")
	a.phase = .Initializing
}

// app_enter_running moves Initializing -> Running. Call it once the
// backend is up and the first frame is about to render.
app_enter_running :: proc(a: ^App) {
	assert(a.phase == .Initializing, "lifecycle: enter_running from non-Initializing phase")
	a.phase = .Running
}

// app_request_quit records a quit request and moves
// Initializing/Running -> Quitting. Repeated requests while already
// Quitting are no-ops and the first reason wins.
//
// `.Init_Failed`/`.Fatal_Error` require a non-sentinel `err`, which is
// transferred into `a.fatal_error` (ownership passes to the App on
// success only).
app_request_quit :: proc(a: ^App, reason: Quit_Reason, err := errs.Error{}) {
	assert(reason != .None, "lifecycle: request_quit with reason .None")
	assert(
		a.phase == .Initializing || a.phase == .Running || a.phase == .Quitting,
		"lifecycle: request_quit from invalid phase",
	)
	if a.phase == .Quitting {
		return // idempotent; the first request wins
	}
	if reason == .Init_Failed || reason == .Fatal_Error {
		assert(!errs.ok(err), "lifecycle: fatal quit reasons require an error")
	}
	a.phase = .Quitting
	a.quit_reason = reason
	a.fatal_error = err
}

// app_cancel_quit moves Quitting -> Running. Only user-requested quits
// can be cancelled; M04.06 uses this for "Cancel" in the dirty-buffer
// review. Fatal errors must never be silently discarded.
app_cancel_quit :: proc(a: ^App) {
	assert(a.phase == .Quitting, "lifecycle: cancel_quit from non-Quitting phase")
	assert(
		a.quit_reason == .User_Request,
		"lifecycle: only user-requested quits can be cancelled",
	)
	a.phase = .Running
	a.quit_reason = .None
}

// app_enter_shutdown moves Quitting -> Shutdown. Call it from the
// backend cleanup callback once all services are stopped.
app_enter_shutdown :: proc(a: ^App) {
	assert(a.phase == .Quitting, "lifecycle: enter_shutdown from non-Quitting phase")
	a.phase = .Shutdown
}

// app_enter_exited moves Shutdown -> Exited. Call it after the main
// loop has returned, as the last lifecycle step before exit.
app_enter_exited :: proc(a: ^App) {
	assert(a.phase == .Shutdown, "lifecycle: enter_exited from non-Shutdown phase")
	a.phase = .Exited
}

// app_is_quitting reports whether a quit has been requested and not
// cancelled (phase Quitting or beyond).
app_is_quitting :: proc(a: ^App) -> bool {
	return a.phase >= .Quitting
}

// app_destroy releases resources owned by the App (the fatal error
// message). Safe to call on a zero App.
app_destroy :: proc(a: ^App) {
	errs.destroy(&a.fatal_error)
	a^ = {}
}
