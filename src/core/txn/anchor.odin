// Anchor transformation (M02.06), in package txn.
//
// Anchors are stable positions that survive edits (SPECS.md §8.3): a
// plain integer offset is not enough for delayed clipboard results,
// asynchronous pipes, IPC clients, layout restoration, or multiple
// views. An anchor records its byte position, an affinity, and the
// document revision it was captured at; `anchor_transform` replays
// the applied transaction log (the M02.05 log, in applied order) to
// bring it to the current revision.
//
// Affinity semantics (an insertion exactly at the anchor's position):
//
// - **Left**: the anchor belongs to the text on its left — the
//   inserted text lands between that text and the anchor, so the
//   anchor moves past it (pos += inserted length).
// - **Right**: the anchor belongs to the text on its right — the
//   anchor stays put and the inserted text lands after it.
//
// Deletion rules: an anchor before the removed range is untouched; an
// anchor inside it collapses to the range start; an anchor at or after
// the range end shifts left by the removed length. A replace is the
// engine's delete-then-insert with one refinement: an anchor exactly
// at the range end stays adjacent to the text that followed the range
// (it lands after the replacement, regardless of affinity).
//
// The transform depends only on operation positions and inserted
// lengths — the log's operation copies carry both. An anchor captured
// at any past revision is replayable: the log is never pruned in
// M02.06 (retention is M02.07/M04's concern).
package txn

import errs "../errs"
import rope "../rope"

// Affinity picks which side of an insertion at the anchor's position
// the anchor sticks to.
Affinity :: enum u8 {
	Left,
	Right,
}

// Anchor is a stable byte position with an affinity, captured at
// `revision` of its document. Pass by pointer to `anchor_transform`.
Anchor :: struct {
	pos:      int,
	affinity: Affinity,
	revision: u64,
}

// anchor_at captures an anchor at the document's current revision.
// `pos` must lie in [0, byte_count] (`.Invalid_Input` otherwise).
anchor_at :: proc(
	doc: ^Doc,
	pos: int,
	affinity: Affinity,
	allocator := context.allocator,
) -> (Anchor, errs.Error) {
	total := rope.tree_byte_count(&doc.tree)
	if pos < 0 || pos > total {
		return Anchor{}, errs.newf(
			.Invalid_Input,
			"txn: anchor position %v outside [0, %v]",
			pos,
			total,
			allocator = allocator,
		)
	}
	return Anchor{pos = pos, affinity = affinity, revision = doc.revision}, {}
}

// anchor_transform replays the applied transactions from the anchor's
// captured revision up to the document's current revision, updating
// the anchor in place.
//
// - An anchor revision ahead of the document is `.Invalid_Input`
//   (the anchor came from a document state that does not exist here);
//   an anchor at the current revision is a no-op.
// - `anchor.revision` is set to the current revision on success.
anchor_transform :: proc(doc: ^Doc, anchor: ^Anchor, allocator := context.allocator) -> errs.Error {
	if anchor.revision > doc.revision {
		return errs.newf(
			.Invalid_Input,
			"txn: anchor revision %v is ahead of the document revision %v",
			anchor.revision,
			doc.revision,
			allocator = allocator,
		)
	}
	if anchor.revision == doc.revision {
		return {}
	}
	for &entry in doc.log {
		if entry.base < anchor.revision {
			continue
		}
		for op in entry.ops {
			anchor_apply_op(anchor, op)
		}
	}
	anchor.revision = doc.revision
	return {}
}

// anchor_apply_op transforms the anchor through one operation (the
// applied-order rules; see the package doc).
anchor_apply_op :: proc(anchor: ^Anchor, op: Operation) {
	switch o in op {
	case Insert:
		l := len(o.data)
		if l == 0 {
			return
		}
		if anchor.pos > o.pos || (anchor.pos == o.pos && anchor.affinity == .Left) {
			anchor.pos += l
		}
	case Delete:
		lo := o.range.start
		hi := o.range.end
		if hi <= lo {
			return
		}
		if anchor.pos > lo {
			if anchor.pos >= hi {
				anchor.pos -= hi - lo
			} else {
				anchor.pos = lo
			}
		}
	case Replace:
		lo := o.range.start
		hi := o.range.end
		l := len(o.data)
		if hi <= lo {
			// Empty range: a pure insert at lo.
			if l > 0 && (anchor.pos > lo || (anchor.pos == lo && anchor.affinity == .Left)) {
				anchor.pos += l
			}
			return
		}
		if anchor.pos < lo {
			return
		}
		if anchor.pos == hi {
			// Adjacent to the text that followed the replaced range:
			// stay adjacent to it, after the replacement.
			anchor.pos = lo + l
			return
		}
		if anchor.pos == lo {
			if anchor.affinity == .Left && l > 0 {
				anchor.pos += l
			}
			return
		}
		if anchor.pos < hi {
			// Inside the replaced range: collapse to the start, then
			// the insertion affinity applies.
			anchor.pos = lo
			if anchor.affinity == .Left && l > 0 {
				anchor.pos += l
			}
			return
		}
		anchor.pos = anchor.pos - (hi - lo) + l
	}
}
