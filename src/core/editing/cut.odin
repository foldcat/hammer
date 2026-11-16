package editing

import errs "../errs"
import txn "../txn"

// Cut_Target identifies the buffer state and view selection captured when a
// clipboard write starts. The anchors can advance along the current history path
// while the write result is pending.
Cut_Target :: struct {
	buffer_id:          u64,
	generation:         u64,
	request_id:         u64,
	source_revision:    u64,
	anchor:             txn.Anchor,
	active:             txn.Anchor,
	selection_affinity: txn.Affinity,
}

// Delayed_Cut is a fixed-location, view-owned pending request. It owns no
// allocations and retains no document or selection pointers.
Delayed_Cut :: struct {
	target:  Cut_Target,
	pending: bool,
}

// delayed_cut_begin captures a nonempty selection without starting platform I/O.
// The caller starts a clipboard write with request_id only after this succeeds.
delayed_cut_begin :: proc(
	cut: ^Delayed_Cut,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	buffer_id, generation, request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if cut == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed cut", allocator = allocator)
	}
	if cut.pending {
		return errs.new(.Conflict, "editing: a delayed cut is already pending", allocator = allocator)
	}
	if doc == nil || selection == nil {
		return errs.new(.Invalid_Input, "editing: cut target is not available", allocator = allocator)
	}
	if buffer_id == 0 || request_id == 0 {
		return errs.new(.Invalid_Input, "editing: cut target and request IDs must be nonzero", allocator = allocator)
	}
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}
	if selection.anchor == selection.active {
		return errs.new(.Invalid_Input, "editing: cannot cut an empty selection", allocator = allocator)
	}

	anchor, anchor_err := txn.anchor_at(doc, selection.anchor, selection.affinity, allocator)
	if !errs.ok(anchor_err) {
		return anchor_err
	}
	active, active_err := txn.anchor_at(doc, selection.active, selection.affinity, allocator)
	if !errs.ok(active_err) {
		return active_err
	}
	cut.target = Cut_Target {
		buffer_id = buffer_id,
		generation = generation,
		request_id = request_id,
		source_revision = txn.doc_revision(doc),
		anchor = anchor,
		active = active,
		selection_affinity = selection.affinity,
	}
	cut.pending = true
	return {}
}

// delayed_cut_cancel rejects later completion of request_id. Clipboard data
// already published by a native write remains available.
delayed_cut_cancel :: proc(
	cut: ^Delayed_Cut,
	request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if cut == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed cut", allocator = allocator)
	}
	if !cut.pending {
		return errs.new(.Conflict, "editing: no delayed cut is pending", allocator = allocator)
	}
	if cut.target.request_id != request_id {
		return errs.new(.Conflict, "editing: delayed-cut request ID does not match", allocator = allocator)
	}
	cut^ = Delayed_Cut{}
	return {}
}

// delayed_cut_apply consumes a successful clipboard-write result and deletes the
// captured selection through one Cut transaction. Identity mismatches leave the
// request pending; all other failures leave document text and selection unchanged.
delayed_cut_apply :: proc(
	cut: ^Delayed_Cut,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	buffer_id, generation, request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if cut == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed cut", allocator = allocator)
	}
	if !cut.pending {
		return errs.new(.Conflict, "editing: delayed-cut result is late or already consumed", allocator = allocator)
	}
	target := cut.target
	if target.request_id != request_id {
		return errs.new(.Conflict, "editing: delayed-cut request ID does not match", allocator = allocator)
	}
	if target.buffer_id != buffer_id || target.generation != generation {
		return errs.newf(
			.Conflict,
			"editing: delayed-cut target %d/%d does not match %d/%d",
			buffer_id,
			generation,
			target.buffer_id,
			target.generation,
			allocator = allocator,
		)
	}

	cut^ = Delayed_Cut{}
	if doc == nil || selection == nil {
		return errs.new(.Invalid_Input, "editing: delayed-cut target is not available", allocator = allocator)
	}

	anchor := target.anchor
	if err := txn.anchor_transform(doc, &anchor, allocator); !errs.ok(err) {
		return err
	}
	active := target.active
	if err := txn.anchor_transform(doc, &active, allocator); !errs.ok(err) {
		return err
	}
	captured := txn.Selection {
		anchor = anchor.pos,
		active = active.pos,
		affinity = target.selection_affinity,
	}
	if err := validate_edit_selection(doc, captured, allocator); !errs.ok(err) {
		return err
	}

	range := selection_range(captured)
	if range.start == range.end {
		return errs.new(.Conflict, "editing: delayed-cut selection became empty", allocator = allocator)
	}
	after := txn.Selection{anchor = range.start, active = range.start, affinity = .Left}
	ops := []txn.Operation{txn.Delete{range = range}}
	transaction := txn.Transaction {
		source = .Cut,
		base_revision = txn.doc_revision(doc),
		ops = ops,
		after_selection = after,
	}
	if err := txn.doc_apply(doc, &transaction, allocator); !errs.ok(err) {
		return err
	}
	selection^ = after
	return {}
}
