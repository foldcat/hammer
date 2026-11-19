package edit

import "base:runtime"
import mem_virtual "core:mem/virtual"
import "core:sync"
import "core:thread"

import address "../address"
import errs "../errs"
import rope "../rope"
import txn "../txn"

Request_ID :: distinct u64

Transaction_Batch :: struct {
	ops:             []txn.Operation,
	after_selection: txn.Selection,
}

// Result and its batches borrow runner-owned snapshot storage. Consume the
// result before runner_release or runner_destroy.
Result :: struct {
	target_id:         u64,
	target_generation: u64,
	source_revision:   u64,
	request_id:        Request_ID,
	grouping_key:      u64,
	batches:           []Transaction_Batch,
	selection:         txn.Selection,
	history:           address.Regex_History,
	err:               errs.Error,
}

// Runner holds at most one job. The job arena owns the program, private
// document snapshot, result batches, and errors. Runner is fixed-location
// state: pass by pointer and do not copy it while active.
Runner :: struct {
	arena:             mem_virtual.Arena,
	arena_ready:       bool,
	thread:            ^thread.Thread,
	active:            bool,
	cancel:            bool,
	program:           Program,
	program_ready:     bool,
	doc:               txn.Doc,
	doc_ready:         bool,
	selection:         txn.Selection,
	history:           address.Regex_History,
	result:            Result,
}

runner_start :: proc(
	runner: ^Runner,
	doc: ^txn.Doc,
	selection: txn.Selection,
	program: ^Program,
	history: address.Regex_History,
	target_id: u64,
	target_generation: u64,
	source_revision: u64,
	request_id: Request_ID,
	grouping_key: u64,
	allocator := context.allocator,
) -> errs.Error {
	if runner == nil || doc == nil || program == nil {
		return errs.new(.Invalid_Input, "edit: nil asynchronous execution input", allocator = allocator)
	}
	if runner.active || runner.arena_ready {
		return errs.new(.Resource_Limit, "edit: an asynchronous edit is already active", allocator = allocator)
	}
	if target_id == 0 || target_generation == 0 || grouping_key == 0 {
		return errs.new(.Invalid_Input, "edit: asynchronous target and undo group must be nonzero", allocator = allocator)
	}
	if !txn.selection_in_bounds(selection, rope.tree_byte_count(&doc.tree)) {
		return errs.new(.Invalid_Input, "edit: asynchronous selection is outside the document", allocator = allocator)
	}
	if arena_err := mem_virtual.arena_init_growing(&runner.arena); arena_err != .None {
		return errs.newf(.Resource_Limit, "edit: cannot initialize worker arena: %v", arena_err, allocator = allocator)
	}
	runner.arena_ready = true
	arena := mem_virtual.arena_allocator(&runner.arena)
	runner.result = {
		target_id = target_id,
		target_generation = target_generation,
		source_revision = source_revision,
		request_id = request_id,
		grouping_key = grouping_key,
	}
	runner.selection = selection
	runner.history = history
	runner.result.selection = selection
	runner.result.history = history

	runner.program_ready = true
	runner.program.commands = make([dynamic]Command, arena)
	runner.program.text = make([dynamic]u8, arena)
	if reserve_err := reserve(&runner.program.commands, len(program.commands)); reserve_err != .None {
		runner_reset(runner)
		return errs.new(.Resource_Limit, "edit: cannot copy worker commands", allocator = allocator)
	}
	if reserve_err := reserve(&runner.program.text, len(program.text)); reserve_err != .None {
		runner_reset(runner)
		return errs.new(.Resource_Limit, "edit: cannot copy worker text", allocator = allocator)
	}
	append(&runner.program.commands, ..program.commands[:])
	append(&runner.program.text, ..program.text[:])

	source, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, arena)
	if !errs.ok(read_err) {
		owned := errs.new(read_err.kind, read_err.message, allocator = allocator)
		errs.destroy(&read_err)
		runner_reset(runner)
		return owned
	}
	defer delete(source, arena)
	if init_err := txn.doc_init_from_bytes(&runner.doc, source, {}, arena); !errs.ok(init_err) {
		owned := errs.new(init_err.kind, init_err.message, allocator = allocator)
		errs.destroy(&init_err)
		runner_reset(runner)
		return owned
	}
	runner.doc_ready = true

	ctx := runtime.default_context()
	ctx.allocator = arena
	ctx.temp_allocator = arena
	{
		previous := context.allocator
		defer context.allocator = previous
		context.allocator = allocator
		runner.thread = thread.create(edit_worker)
	}
	if runner.thread == nil {
		runner_reset(runner)
		return errs.new(.Resource_Limit, "edit: cannot create worker thread", allocator = allocator)
	}
	runner.thread.data = runner
	runner.thread.init_context = ctx
	runner.active = true
	thread.start(runner.thread)
	return {}
}

edit_worker :: proc(thread_handle: ^thread.Thread) {
	runner := cast(^Runner)thread_handle.data
	arena := mem_virtual.arena_allocator(&runner.arena)
	runner.result.err = execute(
		&runner.doc,
		&runner.selection,
		&runner.program,
		&runner.history,
		runner.result.grouping_key,
		arena,
		&runner.cancel,
	)
	if runner.result.err.kind == .Cancelled {
		return
	}
	batches, alloc_err := make([]Transaction_Batch, len(runner.doc.log), arena)
	if alloc_err != .None {
		runner.result.err = errs.new(.Resource_Limit, "edit: cannot allocate worker result", allocator = arena)
		return
	}
	for entry, index in runner.doc.log {
		batches[index] = {ops = entry.ops, after_selection = entry.after_selection}
	}
	runner.result.batches = batches
	runner.result.selection = runner.selection
	runner.result.history = runner.history
}

runner_active :: proc(runner: ^Runner) -> bool {
	return runner != nil && runner.active
}

runner_cancel :: proc(runner: ^Runner) {
	if runner == nil || !runner.active {
		return
	}
	sync.atomic_store(&runner.cancel, true)
}

// runner_poll never waits for active work. A ready result remains valid and
// available until runner_release; thread completion synchronizes result reads.
runner_poll :: proc(runner: ^Runner) -> (^Result, bool) {
	if runner == nil || !runner.active {
		return nil, false
	}
	if runner.thread != nil {
		if !thread.is_done(runner.thread) {
			return nil, false
		}
		thread.join(runner.thread)
		thread.destroy(runner.thread)
		runner.thread = nil
	}
	return &runner.result, true
}

runner_release :: proc(runner: ^Runner) {
	if runner == nil {
		return
	}
	if runner.thread != nil {
		runner_cancel(runner)
		thread.join(runner.thread)
		thread.destroy(runner.thread)
		runner.thread = nil
	}
	runner_reset(runner)
}

runner_destroy :: proc(runner: ^Runner) {
	runner_release(runner)
}

runner_reset :: proc(runner: ^Runner) {
	if runner.arena_ready && (runner.doc_ready || runner.program_ready) {
		arena := mem_virtual.arena_allocator(&runner.arena)
		previous := context.allocator
		context.allocator = arena
		if runner.doc_ready {
			txn.doc_destroy(&runner.doc)
			runner.doc_ready = false
		}
		if runner.program_ready {
			program_destroy(&runner.program, arena)
			runner.program_ready = false
		}
		context.allocator = previous
	}
	if runner.arena_ready {
		mem_virtual.arena_free_all(&runner.arena)
		mem_virtual.arena_destroy(&runner.arena)
	}
	runner^ = {}
}

// apply_result validates all revision metadata before changing live state.
// Successful command prefixes are replayed in order through the transaction
// engine. Cancellation and stale results apply nothing.
apply_result :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	history: ^address.Regex_History,
	result: ^Result,
	target_id: u64,
	target_generation: u64,
	request_id: Request_ID,
	allocator := context.allocator,
) -> errs.Error {
	if doc == nil || selection == nil || history == nil || result == nil {
		return errs.new(.Invalid_Input, "edit: nil result application input", allocator = allocator)
	}
	if result.target_id != target_id || result.target_generation != target_generation || result.request_id != request_id {
		return errs.new(.Conflict, "edit: result target or request is stale", allocator = allocator)
	}
	if result.source_revision != txn.doc_revision(doc) {
		return errs.newf(
			.Conflict,
			"edit: source revision %d is stale; current revision is %d",
			result.source_revision,
			txn.doc_revision(doc),
			allocator = allocator,
		)
	}
	if result.err.kind == .Cancelled {
		return errs.new(.Cancelled, result.err.message, allocator = allocator)
	}
	if len(result.batches) > MAX_COMMANDS {
		return errs.new(.Invalid_Input, "edit: result contains too many transactions", allocator = allocator)
	}
	for batch in result.batches {
		transaction := txn.Transaction{
			source = .Edit,
			base_revision = txn.doc_revision(doc),
			grouping_key = result.grouping_key,
			ops = batch.ops,
			after_selection = batch.after_selection,
		}
		if err := txn.doc_apply(doc, &transaction, allocator); !errs.ok(err) {
			return err
		}
	}
	if !txn.selection_in_bounds(result.selection, rope.tree_byte_count(&doc.tree)) {
		return errs.new(.Internal, "edit: worker returned an out-of-bounds selection", allocator = allocator)
	}
	selection^ = result.selection
	history^ = result.history
	if !errs.ok(result.err) {
		return errs.new(result.err.kind, result.err.message, allocator = allocator)
	}
	return {}
}
