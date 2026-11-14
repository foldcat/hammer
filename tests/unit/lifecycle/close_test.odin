package lifecycle_test

import mem_virtual "core:mem/virtual"
import "core:testing"

import errs "hammer:core/errs"
import lifecycle "hammer:core/lifecycle"

close_expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	description := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected error: %s", description)
	delete(description, context.allocator)
	local := err
	errs.destroy(&local)
	return false
}

close_expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got error %v, expected %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

close_init :: proc(t: ^testing.T, guard: ^lifecycle.Close_Guard, max_buffers := 0) {
	close_expect_ok(t, lifecycle.close_guard_init(guard, {max_buffers = max_buffers}, context.allocator))
}

close_buffer :: proc(id, revision: u64, view_count: int, dirty: bool) -> lifecycle.Buffer_Snapshot {
	return lifecycle.Buffer_Snapshot {
		id = id,
		generation = 100 + id,
		revision = revision,
		view_count = view_count,
		dirty = dirty,
	}
}

close_quit :: proc(origin: lifecycle.Close_Origin) -> lifecycle.Close_Request {
	return lifecycle.Close_Request{kind = .Quit, origin = origin}
}

close_view :: proc(buffer: lifecycle.Buffer_Snapshot, origin := lifecycle.Close_Origin.Mouse) -> lifecycle.Close_Request {
	return lifecycle.Close_Request {
		kind = .Close_View,
		origin = origin,
		buffer_id = buffer.id,
		buffer_generation = buffer.generation,
	}
}

close_buffer_request :: proc(buffer: lifecycle.Buffer_Snapshot, origin := lifecycle.Close_Origin.IPC) -> lifecycle.Close_Request {
	return lifecycle.Close_Request {
		kind = .Close_Buffer,
		origin = origin,
		buffer_id = buffer.id,
		buffer_generation = buffer.generation,
	}
}

@(test)
test_close_all_origins_share_decision_path :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffers := []lifecycle.Buffer_Snapshot{close_buffer(1, 9, 1, true)}
	origins := []lifecycle.Close_Origin {.Keyboard, .Mouse, .Tag_Command, .OS_Close, .IPC, .Filesystem}
	for origin in origins {
		close_expect_ok(t, lifecycle.close_request(&guard, close_quit(origin), buffers))
		testing.expect(t, guard.phase == .Await_Decision)
		testing.expect(t, guard.request.origin == origin)
		testing.expect(t, len(lifecycle.close_pending(&guard)) == 1)
		close_expect_kind(t, lifecycle.close_finish(&guard), .Conflict)
		testing.expect(t, guard.phase == .Await_Decision)
		close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
		testing.expect(t, guard.phase == .Idle)
		testing.expect(t, !lifecycle.close_guard_ready(&guard))
		testing.expect(t, len(lifecycle.close_pending(&guard)) == 0)
	}
}

@(test)
test_close_view_and_buffer_rules :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	shared := close_buffer(11, 8, 2, true)

	// Another view retains the dirty buffer, so closing this view is safe.
	close_expect_ok(t, lifecycle.close_request(&guard, close_view(shared), {shared}))
	testing.expect(t, guard.phase == .Ready)
	testing.expect(t, len(lifecycle.close_pending(&guard)) == 0)
	close_expect_ok(t, lifecycle.close_finish(&guard))

	// The last view and a direct buffer close use the same dirty review.
	shared.view_count = 1
	close_expect_ok(t, lifecycle.close_request(&guard, close_view(shared, .OS_Close), {shared}))
	testing.expect(t, guard.phase == .Await_Decision)
	testing.expect(t, len(lifecycle.close_pending(&guard)) == 1)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
	shared.view_count = 0
	close_expect_ok(t, lifecycle.close_request(&guard, close_buffer_request(shared), {shared}))
	testing.expect(t, guard.phase == .Await_Decision)
	testing.expect(t, len(lifecycle.close_pending(&guard)) == 1)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))

	clean := close_buffer(12, 0, 0, false)
	close_expect_ok(t, lifecycle.close_request(&guard, close_buffer_request(clean, .Filesystem), {clean}))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))
	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {clean}))
	testing.expect(t, guard.phase == .Ready)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_close_save_all_validates_completions :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	first := close_buffer(1, 5, 1, true)
	clean := close_buffer(2, 7, 1, false)
	untitled := close_buffer(3, 11, 1, true)
	buffers := []lifecycle.Buffer_Snapshot {first, clean, untitled}
	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.Keyboard), buffers))
	testing.expect(t, len(lifecycle.close_pending(&guard)) == 2)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Save_All))
	testing.expect(t, guard.phase == .Saving)

	current, ok := lifecycle.close_current(&guard)
	testing.expect(t, ok && current.id == first.id)
	close_expect_kind(t, lifecycle.close_save_succeeded(&guard, first.id, first.generation, first.revision + 1, first.revision), .Conflict)
	close_expect_kind(t, lifecycle.close_save_succeeded(&guard, first.id, first.generation, first.revision, first.revision + 1), .Conflict)
	close_expect_kind(t, lifecycle.close_save_succeeded(&guard, untitled.id, untitled.generation, untitled.revision, untitled.revision), .Conflict)
	testing.expect(t, guard.phase == .Saving && guard.next == 0)
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, first.id, first.generation, first.revision, first.revision))
	testing.expect(t, guard.phase == .Saving && guard.next == 1)
	current, ok = lifecycle.close_current(&guard)
	testing.expect(t, ok && current.id == untitled.id)
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, untitled.id, untitled.generation, untitled.revision, untitled.revision))
	testing.expect(t, guard.phase == .Ready)
	pending := lifecycle.close_pending(&guard)
	testing.expect(t, len(pending) == 2)
	testing.expect(t, pending[0].resolution == .Saved && pending[1].resolution == .Saved)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_close_review_unsaved_per_buffer :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffers := []lifecycle.Buffer_Snapshot {close_buffer(4, 1, 1, true), close_buffer(8, 2, 0, true)}
	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.Tag_Command), buffers))
	close_expect_kind(t, lifecycle.close_decision(&guard, .Save_Current), .Conflict)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Review_Unsaved))
	testing.expect(t, guard.phase == .Reviewing)

	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_Current))
	testing.expect(t, guard.phase == .Reviewing && guard.next == 1)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Save_Current))
	testing.expect(t, guard.phase == .Saving)
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, 8, 108, 2, 2))
	testing.expect(t, guard.phase == .Ready)
	pending := lifecycle.close_pending(&guard)
	testing.expect(t, pending[0].resolution == .Discarded)
	testing.expect(t, pending[1].resolution == .Saved)
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_close_discard_is_explicit :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	buffer := close_buffer(7, 3, 1, true)
	close_expect_ok(t, lifecycle.close_request(&guard, close_buffer_request(buffer), {buffer}))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_All))
	testing.expect(t, guard.phase == .Ready)
	pending := lifecycle.close_pending(&guard)
	testing.expect(t, len(pending) == 1 && pending[0].resolution == .Discarded)
	close_expect_kind(t, lifecycle.close_decision(&guard, .Cancel), .Conflict)
	close_expect_ok(t, lifecycle.close_finish(&guard))
	testing.expect(t, guard.phase == .Idle)
}

@(test)
test_close_cancel_rejects_late_save :: proc(t: ^testing.T) {
	guard: lifecycle.Close_Guard
	close_init(t, &guard)
	defer lifecycle.close_guard_destroy(&guard)
	first := close_buffer(1, 1, 1, true)
	second := close_buffer(2, 2, 1, true)
	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.OS_Close), {first, second}))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Save_All))
	close_expect_ok(t, lifecycle.close_save_succeeded(&guard, first.id, first.generation, first.revision, first.revision))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
	testing.expect(t, guard.phase == .Idle)
	close_expect_kind(t, lifecycle.close_save_succeeded(&guard, second.id, second.generation, second.revision, second.revision), .Conflict)
	testing.expect(t, !lifecycle.close_guard_ready(&guard))

	// A canceled request can be started again without stale resolutions.
	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.OS_Close), {first, second}))
	close_expect_ok(t, lifecycle.close_decision(&guard, .Discard_All))
	testing.expect(t, guard.phase == .Ready)
	for buffer in lifecycle.close_pending(&guard) {
		testing.expect(t, buffer.resolution == .Discarded)
	}
	close_expect_ok(t, lifecycle.close_finish(&guard))
}

@(test)
test_close_validation_and_bounds :: proc(t: ^testing.T) {
	uninitialized: lifecycle.Close_Guard
	close_expect_kind(t, lifecycle.close_request(&uninitialized, close_quit(.Keyboard), {}), .Invalid_Input)
	lifecycle.close_guard_destroy(&uninitialized)

	negative: lifecycle.Close_Guard
	close_expect_kind(t, lifecycle.close_guard_init(&negative, {max_buffers = -1}), .Invalid_Input)
	lifecycle.close_guard_destroy(&negative)

	guard: lifecycle.Close_Guard
	close_init(t, &guard, 2)
	defer lifecycle.close_guard_destroy(&guard)
	one := close_buffer(1, 1, 1, true)
	two := close_buffer(2, 2, 1, true)
	three := close_buffer(3, 3, 1, false)
	close_expect_kind(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {one, two, three}), .Resource_Limit)
	testing.expect(t, guard.phase == .Idle)
	close_expect_kind(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {one, one}), .Invalid_Input)
	close_expect_kind(t, lifecycle.close_request(&guard, close_buffer_request(two), {one}), .NotFound)
	stale := close_buffer_request(one)
	stale.buffer_generation += 1
	close_expect_kind(t, lifecycle.close_request(&guard, stale, {one}), .Conflict)
	invalid := close_buffer_request(one)
	invalid.buffer_id = 0
	invalid.buffer_generation = 0
	close_expect_kind(t, lifecycle.close_request(&guard, invalid, {one}), .Invalid_Input)
	no_views := one
	no_views.view_count = 0
	close_expect_kind(t, lifecycle.close_request(&guard, close_view(no_views), {no_views}), .Invalid_Input)
	negative_views := one
	negative_views.view_count = -1
	close_expect_kind(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {negative_views}), .Invalid_Input)
	invalid_origin := close_quit(lifecycle.Close_Origin(99))
	close_expect_kind(t, lifecycle.close_request(&guard, invalid_origin, {one}), .Invalid_Input)
	invalid_kind := close_quit(.Keyboard)
	invalid_kind.kind = lifecycle.Close_Kind(99)
	close_expect_kind(t, lifecycle.close_request(&guard, invalid_kind, {one}), .Invalid_Input)
	quit_with_target := close_quit(.Keyboard)
	quit_with_target.buffer_id = one.id
	close_expect_kind(t, lifecycle.close_request(&guard, quit_with_target, {one}), .Invalid_Input)

	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {one}))
	close_expect_kind(t, lifecycle.close_request(&guard, close_quit(.Keyboard), {one}), .Conflict)
	close_expect_kind(t, lifecycle.close_decision(&guard, lifecycle.Close_Decision(99)), .Invalid_Input)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
	testing.expect(t, guard.phase == .Idle)
}

@(test)
test_close_allocation_failure_is_atomic :: proc(t: ^testing.T) {
	storage := make([]byte, 512, context.allocator)
	defer delete(storage, context.allocator)
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_buffer(&arena, storage) == nil)
	defer mem_virtual.arena_destroy(&arena)
	allocator := mem_virtual.arena_allocator(&arena)
	guard: lifecycle.Close_Guard
	close_expect_ok(t, lifecycle.close_guard_init(&guard, {}, allocator))
	defer lifecycle.close_guard_destroy(&guard)

	buffers: [32]lifecycle.Buffer_Snapshot
	for &buffer, index in buffers {
		buffer = close_buffer(u64(index + 1), u64(index + 10), 1, true)
	}
	close_expect_kind(t, lifecycle.close_request(&guard, close_quit(.Keyboard), buffers[:]), .Resource_Limit)
	testing.expect(t, guard.phase == .Idle)
	testing.expect(t, len(lifecycle.close_pending(&guard)) == 0)

	close_expect_ok(t, lifecycle.close_request(&guard, close_quit(.Keyboard), buffers[:1]))
	testing.expect(t, guard.phase == .Await_Decision)
	close_expect_ok(t, lifecycle.close_decision(&guard, .Cancel))
}
