// Dirty-buffer close/quit decisions and save-failure blocking (M04.06–M04.07,
// SPECS.md §11.6).
//
// Close_Guard is the single headless decision path for keyboard, mouse, tag,
// OS, IPC, and filesystem-originated requests. It does not execute saves,
// destroy buffers/views, or stop services. A caller may perform those actions
// only after the guard reaches Ready. Failed saves and canceled Save As enter
// Save_Failed and require an explicit retry, Save As, review, discard, or cancel.
package lifecycle

import "base:runtime"

import errs "../errs"

DEFAULT_MAX_CLOSE_BUFFERS :: 4096

Close_Kind :: enum {
	Quit,
	Close_View,
	Close_Buffer,
}

Close_Origin :: enum {
	Keyboard,
	Mouse,
	Tag_Command,
	OS_Close,
	IPC,
	Filesystem,
}

Close_Request :: struct {
	kind:              Close_Kind,
	origin:            Close_Origin,
	buffer_id:         u64,
	buffer_generation: u64,
}

// Buffer_Snapshot is borrowed during close_request. Dirty state includes named
// and untitled user work. Generation and revision identify the exact buffer
// state for which a save completion may later be accepted.
Buffer_Snapshot :: struct {
	id:         u64,
	generation: u64,
	revision:   u64,
	view_count: int,
	dirty:      bool,
}

Close_Phase :: enum {
	Idle,
	Await_Decision,
	Reviewing,
	Saving,
	Save_Failed,
	Ready,
}

Close_Decision :: enum {
	Save_All,
	Review_Unsaved,
	Discard_All,
	Save_Current,
	Discard_Current,
	Retry_Save,
	Save_As,
	Cancel,
}

Resolution :: enum {
	Unresolved,
	Saved,
	Discarded,
	Failed,
}

Save_Failure_Kind :: enum {
	Operation_Failed,
	Save_As_Canceled,
}

// Save_Failure describes the current pending buffer. The guard owns cause after
// a successful close_save_failed call. replaced distinguishes post-publication
// errors, which require deliberate Save As/discard/cancel rather than blind retry.
Save_Failure :: struct {
	buffer_id: u64,
	kind:      Save_Failure_Kind,
	cause:     errs.Error,
	replaced:  bool,
}

// Pending_Buffer records one dirty buffer and its explicit resolution. The
// guard owns the pending array, not any referenced editor buffer.
Pending_Buffer :: struct {
	id:         u64,
	generation: u64,
	revision:   u64,
	resolution: Resolution,
}

Close_Options :: struct {
	max_buffers: int, // zero selects the default
}

// Close_Guard is a fixed-location, single-owner value. Initialize before use,
// destroy before reinitialization, and do not copy it. Pending slices returned
// by close_pending are borrowed until the next decision, completion, or reset.
Close_Guard :: struct {
	phase:      Close_Phase,
	request:    Close_Request,
	pending:    [dynamic]Pending_Buffer,
	next:       int,
	reviewing:  bool,
	failure:    Save_Failure,
	max_buffers: int,
	allocator:  runtime.Allocator,
	initialized: bool,
}

close_guard_init :: proc(
	guard: ^Close_Guard,
	options: Close_Options,
	allocator := context.allocator,
) -> errs.Error {
	if guard == nil {
		return errs.newf(.Invalid_Input, "lifecycle: nil close guard", allocator = allocator)
	}
	if guard.initialized {
		return errs.newf(.Conflict, "lifecycle: close guard is already initialized", allocator = allocator)
	}
	if options.max_buffers < 0 {
		return errs.newf(.Invalid_Input, "lifecycle: negative close-buffer limit", allocator = allocator)
	}
	guard.max_buffers = options.max_buffers
	if guard.max_buffers == 0 {
		guard.max_buffers = DEFAULT_MAX_CLOSE_BUFFERS
	}
	guard.allocator = allocator
	guard.pending = make([dynamic]Pending_Buffer, allocator)
	guard.phase = .Idle
	guard.initialized = true
	return {}
}

close_clear_failure :: proc(guard: ^Close_Guard) {
	errs.destroy(&guard.failure.cause)
	guard.failure = Save_Failure{}
}

close_guard_destroy :: proc(guard: ^Close_Guard) {
	if guard == nil {
		return
	}
	if guard.initialized {
		close_clear_failure(guard)
		delete(guard.pending)
	}
	guard^ = Close_Guard{}
}

close_guard_reset :: proc(guard: ^Close_Guard) {
	close_clear_failure(guard)
	clear(&guard.pending)
	guard.phase = .Idle
	guard.request = Close_Request{}
	guard.next = 0
	guard.reviewing = false
}

close_guard_ready :: proc(guard: ^Close_Guard) -> bool {
	return guard != nil && guard.initialized && guard.phase == .Ready
}

// close_pending returns the dirty-buffer snapshot and resolutions. It is empty
// for clean requests and for closing a view that is not the buffer's last view.
close_pending :: proc(guard: ^Close_Guard) -> []Pending_Buffer {
	if guard == nil || !guard.initialized {
		return {}
	}
	return guard.pending[:]
}

// close_current returns the next buffer requiring a save/review decision.
close_current :: proc(guard: ^Close_Guard) -> (Pending_Buffer, bool) {
	if guard == nil || !guard.initialized || guard.next >= len(guard.pending) {
		return {}, false
	}
	if guard.phase != .Reviewing && guard.phase != .Saving && guard.phase != .Save_Failed {
		return {}, false
	}
	return guard.pending[guard.next], true
}

// close_failure borrows the current failure record. The guard retains ownership
// of cause until a decision, cancellation, or destruction clears it.
close_failure :: proc(guard: ^Close_Guard) -> (^Save_Failure, bool) {
	if guard == nil || !guard.initialized || guard.phase != .Save_Failed {
		return nil, false
	}
	return &guard.failure, true
}

close_request_includes :: proc(kind: Close_Kind, buffer: Buffer_Snapshot) -> bool {
	switch kind {
	case .Quit:
		return buffer.dirty
	case .Close_Buffer:
		return buffer.dirty
	case .Close_View:
		return buffer.dirty && buffer.view_count == 1
	}
	return false
}

// close_request captures and validates the dirty-buffer set synchronously.
// Closing one of several views is immediately Ready even when the shared buffer
// is dirty. Closing its last view, closing the buffer, or quitting with dirty
// named/untitled buffers reaches Await_Decision. Clean requests are Ready.
// No editor state is mutated, and a failed request leaves the guard Idle.
close_request :: proc(
	guard: ^Close_Guard,
	request: Close_Request,
	buffers: []Buffer_Snapshot,
	allocator := context.allocator,
) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.newf(.Invalid_Input, "lifecycle: close guard is not initialized", allocator = allocator)
	}
	if guard.phase != .Idle {
		return errs.newf(.Conflict, "lifecycle: a close decision is already active", allocator = guard.allocator)
	}
	if request.origin < .Keyboard || request.origin > .Filesystem {
		return errs.newf(.Invalid_Input, "lifecycle: invalid close origin", allocator = guard.allocator)
	}
	if request.kind == .Quit {
		if request.buffer_id != 0 || request.buffer_generation != 0 {
			return errs.newf(.Invalid_Input, "lifecycle: quit request has a buffer target", allocator = guard.allocator)
		}
	} else if request.kind == .Close_View || request.kind == .Close_Buffer {
		if request.buffer_id == 0 {
			return errs.newf(.Invalid_Input, "lifecycle: close request has no buffer target", allocator = guard.allocator)
		}
	} else {
		return errs.newf(.Invalid_Input, "lifecycle: invalid close kind", allocator = guard.allocator)
	}
	if len(buffers) > guard.max_buffers {
		return errs.newf(.Resource_Limit, "lifecycle: close inspection exceeds the %d-buffer limit", guard.max_buffers, allocator = guard.allocator)
	}

	target_found := request.kind == .Quit
	required := 0
	for buffer, index in buffers {
		if buffer.id == 0 || buffer.view_count < 0 {
			return errs.newf(.Invalid_Input, "lifecycle: invalid buffer snapshot at index %d", index, allocator = guard.allocator)
		}
		for other in buffers[:index] {
			if other.id == buffer.id {
				return errs.newf(.Invalid_Input, "lifecycle: duplicate buffer ID %d", buffer.id, allocator = guard.allocator)
			}
		}
		if request.kind != .Quit && request.buffer_id == buffer.id {
			if target_found {
				return errs.newf(.Invalid_Input, "lifecycle: duplicate close target", allocator = guard.allocator)
			}
			if buffer.generation != request.buffer_generation {
				return errs.newf(.Conflict, "lifecycle: close target generation is stale", allocator = guard.allocator)
			}
			if request.kind == .Close_View && buffer.view_count == 0 {
				return errs.newf(.Invalid_Input, "lifecycle: closing a view of a buffer with no views", allocator = guard.allocator)
			}
			target_found = true
		}
		if request.kind != .Quit && request.buffer_id != buffer.id {
			continue
		}
		if close_request_includes(request.kind, buffer) {
			required += 1
		}
	}
	if !target_found {
		return errs.newf(.NotFound, "lifecycle: close target buffer %d does not exist", request.buffer_id, allocator = guard.allocator)
	}
	if required > guard.max_buffers {
		return errs.newf(.Resource_Limit, "lifecycle: close review exceeds the %d-buffer limit", guard.max_buffers, allocator = guard.allocator)
	}
	if reserve_err := reserve(&guard.pending, required); reserve_err != .None {
		return errs.newf(.Resource_Limit, "lifecycle: reserving close review failed: %v", reserve_err, allocator = guard.allocator)
	}

	guard.request = request
	for buffer in buffers {
		if request.kind != .Quit && request.buffer_id != buffer.id {
			continue
		}
		if buffer.dirty && (request.kind != .Close_View || buffer.view_count == 1) {
			append(&guard.pending, Pending_Buffer {
				id = buffer.id,
				generation = buffer.generation,
				revision = buffer.revision,
			})
		}
	}
	guard.phase = .Await_Decision if len(guard.pending) > 0 else .Ready
	return {}
}

close_advance :: proc(guard: ^Close_Guard) {
	guard.next += 1
	if guard.next == len(guard.pending) {
		guard.phase = .Ready
		guard.reviewing = false
	} else if guard.reviewing {
		guard.phase = .Reviewing
	} else {
		guard.phase = .Saving
	}
}

// close_decision applies save/review/discard/cancel choices. Cancel returns to
// Idle and never reaches Ready; late results are subsequently rejected. A failed
// save may be retried only before publication. Post-publication errors require
// deliberate Save As, explicit discard, or Cancel so callers cannot clobber the
// newly published destination through an automatic retry.
close_decision :: proc(guard: ^Close_Guard, decision: Close_Decision) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: close guard is not initialized")
	}
	if decision == .Cancel {
		if guard.phase != .Await_Decision && guard.phase != .Reviewing &&
			guard.phase != .Saving && guard.phase != .Save_Failed {
			return errs.newf(.Conflict, "lifecycle: no cancellable close decision", allocator = guard.allocator)
		}
		close_guard_reset(guard)
		return {}
	}
	from_failure := guard.phase == .Save_Failed
	switch decision {
	case .Save_All:
		if guard.phase != .Await_Decision {
			return errs.newf(.Conflict, "lifecycle: Save All is not valid in the current close phase", allocator = guard.allocator)
		}
	case .Review_Unsaved:
		if from_failure && guard.failure.replaced {
			return errs.newf(.Conflict, "lifecycle: post-publication failure requires Save As, discard, or cancel", allocator = guard.allocator)
		}
		if guard.phase != .Await_Decision && !from_failure {
			return errs.newf(.Conflict, "lifecycle: Review Unsaved is not valid in the current close phase", allocator = guard.allocator)
		}
	case .Discard_All:
		if guard.phase != .Await_Decision && !from_failure {
			return errs.newf(.Conflict, "lifecycle: Discard All is not valid in the current close phase", allocator = guard.allocator)
		}
	case .Save_Current:
		if guard.phase != .Reviewing {
			return errs.newf(.Conflict, "lifecycle: no current unsaved buffer to save", allocator = guard.allocator)
		}
	case .Discard_Current:
		if guard.phase != .Reviewing && !from_failure {
			return errs.newf(.Conflict, "lifecycle: no current unsaved buffer to discard", allocator = guard.allocator)
		}
	case .Retry_Save:
		if !from_failure || guard.failure.kind != .Operation_Failed || guard.failure.replaced {
			return errs.newf(.Conflict, "lifecycle: this save cannot be retried", allocator = guard.allocator)
		}
	case .Save_As:
		if !from_failure {
			return errs.newf(.Conflict, "lifecycle: Save As requires a failed save or canceled Save As", allocator = guard.allocator)
		}
	case .Cancel:
		unreachable()
	case:
		return errs.newf(.Invalid_Input, "lifecycle: invalid close decision", allocator = guard.allocator)
	}

	switch decision {
	case .Save_All:
		guard.reviewing = false
		guard.next = 0
		guard.phase = .Saving
	case .Review_Unsaved:
		if from_failure {
			guard.pending[guard.next].resolution = .Unresolved
			close_clear_failure(guard)
		} else {
			guard.next = 0
		}
		guard.reviewing = true
		guard.phase = .Reviewing
	case .Discard_All:
		if from_failure {
			close_clear_failure(guard)
		}
		for &buffer in guard.pending {
			buffer.resolution = .Discarded
		}
		guard.phase = .Ready
	case .Save_Current:
		guard.phase = .Saving
	case .Discard_Current:
		if from_failure {
			close_clear_failure(guard)
		}
		guard.pending[guard.next].resolution = .Discarded
		close_advance(guard)
	case .Retry_Save, .Save_As:
		guard.pending[guard.next].resolution = .Unresolved
		close_clear_failure(guard)
		guard.phase = .Saving
	case .Cancel:
		unreachable()
	}
	return {}
}

// close_save_succeeded acknowledges one actually completed save. The result
// must match the pending buffer's stable ID, generation, source revision, and
// current revision. Requiring both revisions to equal the captured value rejects
// stale/out-of-order results and edits that arrived while the save was running.
// Save-time formatting must therefore finish before the close review snapshot.
close_save_succeeded :: proc(
	guard: ^Close_Guard,
	buffer_id, generation, source_revision, current_revision: u64,
) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: close guard is not initialized")
	}
	if guard.phase != .Saving || guard.next >= len(guard.pending) {
		return errs.newf(.Conflict, "lifecycle: no save is awaiting completion", allocator = guard.allocator)
	}
	current := guard.pending[guard.next]
	if current.id != buffer_id || current.generation != generation ||
		current.revision != source_revision || current.revision != current_revision {
		return errs.newf(
			.Conflict,
			"lifecycle: stale save completion for buffer %d (generation %d, source revision %d, current revision %d)",
			buffer_id,
			generation,
			source_revision,
			current_revision,
			allocator = guard.allocator,
		)
	}
	guard.pending[guard.next].resolution = .Saved
	close_advance(guard)
	return {}
}

// close_save_failed records an actual save error and enters Save_Failed. On
// success only, ownership of failure transfers to the guard; on a stale or
// invalid result the caller retains it. The editable buffer and dirty state are
// untouched, and close_finish remains blocked until an explicit decision.
close_save_failed :: proc(
	guard: ^Close_Guard,
	buffer_id, generation, source_revision, current_revision: u64,
	failure: errs.Error,
	replaced: bool,
) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: close guard is not initialized")
	}
	if errs.ok(failure) {
		return errs.newf(.Invalid_Input, "lifecycle: save failure requires an error", allocator = guard.allocator)
	}
	if guard.phase != .Saving || guard.next >= len(guard.pending) {
		return errs.newf(.Conflict, "lifecycle: no save is awaiting a failure result", allocator = guard.allocator)
	}
	current := guard.pending[guard.next]
	if current.id != buffer_id || current.generation != generation ||
		current.revision != source_revision || current.revision != current_revision {
		return errs.newf(
			.Conflict,
			"lifecycle: stale save failure for buffer %d (generation %d, source revision %d, current revision %d)",
			buffer_id,
			generation,
			source_revision,
			current_revision,
			allocator = guard.allocator,
		)
	}
	close_clear_failure(guard)
	guard.failure = Save_Failure {
		buffer_id = buffer_id,
		kind = .Operation_Failed,
		cause = failure,
		replaced = replaced,
	}
	guard.pending[guard.next].resolution = .Failed
	guard.phase = .Save_Failed
	return {}
}

// close_save_as_canceled records a canceled Save As without inventing an I/O
// error. It has the same identity checks and close-blocking behavior as a save
// failure, but only Save As, review, explicit discard, or Cancel can proceed.
close_save_as_canceled :: proc(
	guard: ^Close_Guard,
	buffer_id, generation, source_revision, current_revision: u64,
) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: close guard is not initialized")
	}
	if guard.phase != .Saving || guard.next >= len(guard.pending) {
		return errs.newf(.Conflict, "lifecycle: no Save As is awaiting a cancellation result", allocator = guard.allocator)
	}
	current := guard.pending[guard.next]
	if current.id != buffer_id || current.generation != generation ||
		current.revision != source_revision || current.revision != current_revision {
		return errs.newf(.Conflict, "lifecycle: stale Save As cancellation", allocator = guard.allocator)
	}
	close_clear_failure(guard)
	guard.failure = Save_Failure{buffer_id = buffer_id, kind = .Save_As_Canceled}
	guard.pending[guard.next].resolution = .Failed
	guard.phase = .Save_Failed
	return {}
}

// close_finish clears a Ready request after the caller has performed the
// authorized close/quit actions. It rejects every other phase, so finishing
// cannot bypass inspection, a decision, or outstanding saves.
close_finish :: proc(guard: ^Close_Guard) -> errs.Error {
	if guard == nil || !guard.initialized {
		return errs.new(.Invalid_Input, "lifecycle: close guard is not initialized")
	}
	if guard.phase != .Ready {
		return errs.newf(.Conflict, "lifecycle: close is not ready", allocator = guard.allocator)
	}
	close_guard_reset(guard)
	return {}
}
