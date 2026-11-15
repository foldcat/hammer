package editing

import "core:unicode/utf8"

import errs "../errs"
import txn "../txn"

// Paste_Target identifies the exact buffer state and view selection captured
// when a clipboard read starts. The anchors can advance along the buffer's
// current history path while the read is pending.
Paste_Target :: struct {
	buffer_id:          u64,
	generation:         u64,
	request_id:         u64,
	source_revision:    u64,
	anchor:             txn.Anchor,
	active:             txn.Anchor,
	selection_affinity: txn.Affinity,
}

// Delayed_Paste is a fixed-location, view-owned pending request. It owns no
// allocations and retains no document or selection pointers. One instance
// permits one request at a time; completion or cancellation consumes it.
Delayed_Paste :: struct {
	target:  Paste_Target,
	pending: bool,
}

// delayed_paste_begin captures the current target without starting platform I/O.
// The caller starts a clipboard read with request_id only after this succeeds.
delayed_paste_begin :: proc(
	paste: ^Delayed_Paste,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	buffer_id, generation, request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if paste == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed paste", allocator = allocator)
	}
	if paste.pending {
		return errs.new(.Conflict, "editing: a delayed paste is already pending", allocator = allocator)
	}
	if doc == nil || selection == nil {
		return errs.new(.Invalid_Input, "editing: paste target is not available", allocator = allocator)
	}
	if buffer_id == 0 || request_id == 0 {
		return errs.new(.Invalid_Input, "editing: paste target and request IDs must be nonzero", allocator = allocator)
	}
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}

	anchor, anchor_err := txn.anchor_at(doc, selection.anchor, selection.affinity, allocator)
	if !errs.ok(anchor_err) {
		return anchor_err
	}
	active, active_err := txn.anchor_at(doc, selection.active, selection.affinity, allocator)
	if !errs.ok(active_err) {
		return active_err
	}
	paste.target = Paste_Target {
		buffer_id = buffer_id,
		generation = generation,
		request_id = request_id,
		source_revision = txn.doc_revision(doc),
		anchor = anchor,
		active = active,
		selection_affinity = selection.affinity,
	}
	paste.pending = true
	return {}
}

// delayed_paste_cancel rejects later completion of request_id. The caller also
// cancels the native clipboard read; a result already queued remains harmless.
delayed_paste_cancel :: proc(
	paste: ^Delayed_Paste,
	request_id: u64,
	allocator := context.allocator,
) -> errs.Error {
	if paste == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed paste", allocator = allocator)
	}
	if !paste.pending {
		return errs.new(.Conflict, "editing: no delayed paste is pending", allocator = allocator)
	}
	if paste.target.request_id != request_id {
		return errs.new(.Conflict, "editing: delayed-paste request ID does not match", allocator = allocator)
	}
	paste^ = Delayed_Paste{}
	return {}
}

// delayed_paste_apply consumes a matching clipboard result and replaces the
// captured selection through one Paste transaction. buffer_id and generation
// describe the looked-up destination, never whichever window is now focused.
// Anchors transform through intervening edits on the current history path;
// abandoned history, invalid UTF-8, and transaction failures change no text or
// selection. Identity mismatches leave the request pending for its real result.
delayed_paste_apply :: proc(
	paste: ^Delayed_Paste,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	buffer_id, generation, request_id: u64,
	data: []byte,
	allocator := context.allocator,
) -> errs.Error {
	if paste == nil {
		return errs.new(.Invalid_Input, "editing: nil delayed paste", allocator = allocator)
	}
	if !paste.pending {
		return errs.new(.Conflict, "editing: delayed-paste result is late or already consumed", allocator = allocator)
	}
	target := paste.target
	if target.request_id != request_id {
		return errs.new(.Conflict, "editing: delayed-paste request ID does not match", allocator = allocator)
	}
	if target.buffer_id != buffer_id || target.generation != generation {
		return errs.newf(
			.Conflict,
			"editing: delayed-paste target %d/%d does not match %d/%d",
			buffer_id,
			generation,
			target.buffer_id,
			target.generation,
			allocator = allocator,
		)
	}

	paste^ = Delayed_Paste{}
	if doc == nil || selection == nil {
		return errs.new(.Invalid_Input, "editing: delayed-paste target is not available", allocator = allocator)
	}
	if !utf8.valid_string(string(data)) {
		return errs.new(.Invalid_Input, "editing: clipboard payload is not valid UTF-8", allocator = allocator)
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
	after := txn.Selection{anchor = range.start + len(data), active = range.start + len(data), affinity = .Left}
	operation: txn.Operation
	if range.start == range.end {
		operation = txn.Insert{pos = range.start, data = data}
	} else {
		operation = txn.Replace{range = range, data = data}
	}
	ops := []txn.Operation{operation}
	transaction := txn.Transaction {
		source = .Paste,
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

