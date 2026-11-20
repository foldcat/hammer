package lifecycle

import "base:runtime"

import errs "../errs"

Job_Quit_Phase :: enum u8 {
	Idle,
	Await_Decision,
	Waiting,
	Cancelling,
	Ready,
}

Job_Quit_Decision :: enum u8 {
	Wait,
	Cancel_Jobs,
	Cancel_Exit,
}

// Job_Quit_Guard tracks job decisions separately from dirty-buffer review.
// The caller supplies the number of jobs still requiring process or output
// completion, performs cancellation, and authorizes exit only in Ready.
Job_Quit_Guard :: struct {
	phase:      Job_Quit_Phase,
	origin:     Close_Origin,
	allocator:  runtime.Allocator,
	initialized: bool,
}

job_quit_guard_init :: proc(guard: ^Job_Quit_Guard, allocator := context.allocator) -> errs.Error {
	if guard == nil {
		return errs.new(.Invalid_Input, "lifecycle: nil job quit guard", allocator = allocator)
	}
	if guard.initialized {
		return errs.new(.Conflict, "lifecycle: job quit guard is already initialized", allocator = allocator)
	}
	guard^ = {allocator = allocator, initialized = true}
	return {}
}

job_quit_guard_destroy :: proc(guard: ^Job_Quit_Guard) {
	if guard != nil {
		guard^ = {}
	}
}

job_quit_guard_reset :: proc(guard: ^Job_Quit_Guard) {
	if guard != nil {
		guard.phase = .Idle
		guard.origin = {}
	}
}

job_quit_guard_active :: proc(guard: ^Job_Quit_Guard) -> bool {
	if guard == nil || !guard.initialized {
		return false
	}
	return guard.phase == .Await_Decision || guard.phase == .Waiting || guard.phase == .Cancelling
}

job_quit_guard_ready :: proc(guard: ^Job_Quit_Guard) -> bool {
	return guard != nil && guard.initialized && guard.phase == .Ready
}

job_quit_request :: proc(guard: ^Job_Quit_Guard, origin: Close_Origin, pending_jobs: int) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: job quit guard is not initialized")
	}
	if guard.phase != .Idle {
		return errs.new(.Conflict, "lifecycle: a job quit decision is already active", allocator = guard.allocator)
	}
	if origin < .Keyboard || origin > .Filesystem {
		return errs.new(.Invalid_Input, "lifecycle: invalid job quit origin", allocator = guard.allocator)
	}
	if pending_jobs < 0 {
		return errs.new(.Invalid_Input, "lifecycle: negative pending-job count", allocator = guard.allocator)
	}
	guard.origin = origin
	guard.phase = .Await_Decision if pending_jobs > 0 else .Ready
	return {}
}

job_quit_decision :: proc(guard: ^Job_Quit_Guard, decision: Job_Quit_Decision) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: job quit guard is not initialized")
	}
	if decision == .Cancel_Exit {
		if !job_quit_guard_active(guard) {
			return errs.new(.Conflict, "lifecycle: no job quit decision to cancel", allocator = guard.allocator)
		}
		job_quit_guard_reset(guard)
		return {}
	}
	switch decision {
	case .Wait:
		if guard.phase != .Await_Decision {
			return errs.new(.Conflict, "lifecycle: Wait is not valid in the current job quit phase", allocator = guard.allocator)
		}
		guard.phase = .Waiting
	case .Cancel_Jobs:
		if guard.phase != .Await_Decision && guard.phase != .Waiting {
			return errs.new(.Conflict, "lifecycle: job cancellation is not valid in the current job quit phase", allocator = guard.allocator)
		}
		guard.phase = .Cancelling
	case .Cancel_Exit:
		unreachable()
	case:
		return errs.new(.Invalid_Input, "lifecycle: invalid job quit decision", allocator = guard.allocator)
	}
	return {}
}

job_quit_poll :: proc(guard: ^Job_Quit_Guard, pending_jobs: int) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: job quit guard is not initialized")
	}
	if guard.phase != .Waiting && guard.phase != .Cancelling {
		return errs.new(.Conflict, "lifecycle: no job quit wait is active", allocator = guard.allocator)
	}
	if pending_jobs < 0 {
		return errs.new(.Invalid_Input, "lifecycle: negative pending-job count", allocator = guard.allocator)
	}
	if pending_jobs == 0 {
		guard.phase = .Ready
	}
	return {}
}
