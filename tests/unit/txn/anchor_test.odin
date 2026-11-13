// Tests for anchor transformation (M02.06): `hammer:core/txn`
// anchors — affinity semantics for inserts, delete/replace collapse
// rules, log replay from a captured revision, stale anchors, and a
// randomized differential against an independent reference transform.
package txn_test

import "core:bytes"
import "core:fmt"
import "core:testing"

import errs "hammer:core/errs"
import txn "hammer:core/txn"

// anchor_doc initializes a doc and seeds it with `seed` (one
// transaction). The Doc must not be copied — fill a caller-owned one.
anchor_doc :: proc(t: ^testing.T, doc: ^txn.Doc, seed: string, chunk_size := 4) {
	testing.expect(t, errs.ok(txn.doc_init(doc, {chunk_size = chunk_size})))
	if seed != "" {
		tr: txn.Transaction
		tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, seed)}}
		testing.expect(t, errs.ok(txn.doc_apply(doc, &tr)))
	}
}

// apply_edits applies a list of single-op transactions, expecting
// success.
apply_edits :: proc(t: ^testing.T, doc: ^txn.Doc, edits: []txn.Operation) {
	for op in edits {
		tr: txn.Transaction
		tr = {source = .Edit, base_revision = txn.doc_revision(doc), ops = {op}}
		testing.expect(t, errs.ok(txn.doc_apply(doc, &tr)))
	}
}

// expect_anchor checks the transformed position.
expect_anchor :: proc(t: ^testing.T, doc: ^txn.Doc, a: ^txn.Anchor, want: int, what: string) {
	err := txn.anchor_transform(doc, a)
	testing.expectf(t, errs.ok(err) && a.pos == want, "%s: got %v want %v", what, a.pos, want)
	testing.expect(t, a.revision == txn.doc_revision(doc))
}

// test_anchor_insert_affinity pins the affinity rule for insertions
// exactly at the anchor's position.
@(test)
test_anchor_insert_affinity :: proc(t: ^testing.T) {
	doc: txn.Doc
	anchor_doc(t, &doc, "abcdef")
	defer txn.doc_destroy(&doc)

	a, err := txn.anchor_at(&doc, 3, .Left)
	testing.expect(t, errs.ok(err))
	apply_edits(t, &doc, {insert_op(3, "XY")})
	expect_anchor(t, &doc, &a, 5, "left affinity: insert at anchor")

	b, berr := txn.anchor_at(&doc, 3, .Right)
	testing.expect(t, errs.ok(berr))
	apply_edits(t, &doc, {insert_op(3, "XY")})
	expect_anchor(t, &doc, &b, 3, "right affinity: insert at anchor")

	// Inserts strictly before/after the anchor shift it by the length.
	c, cerr := txn.anchor_at(&doc, 3, .Left)
	testing.expect(t, errs.ok(cerr))
	apply_edits(t, &doc, {insert_op(1, "W")})
	expect_anchor(t, &doc, &c, 4, "insert before the anchor")

	d, derr := txn.anchor_at(&doc, 3, .Right)
	testing.expect(t, errs.ok(derr))
	apply_edits(t, &doc, {insert_op(6, "Z")})
	expect_anchor(t, &doc, &d, 3, "insert after the anchor")
}

// test_anchor_delete_cases pins the delete collapse rules.
@(test)
test_anchor_delete_cases :: proc(t: ^testing.T) {
	doc: txn.Doc
	anchor_doc(t, &doc, "abcdefgh")
	defer txn.doc_destroy(&doc)

	// Delete [2,5) ("cde").
	edits := []txn.Operation{delete_op(2, 5)}
	positions := []int{1, 2, 3, 5, 7}
	wants := []int{1, 2, 2, 2, 4}
	for i in 0 ..< len(positions) {
		a, err := txn.anchor_at(&doc, positions[i], .Left)
		testing.expect(t, errs.ok(err))
		apply_edits(t, &doc, edits)
		expect_anchor(t, &doc, &a, wants[i], fmt.tprintf("delete anchor at %v", positions[i]))
		// Reset the document for the next case.
		txn.doc_destroy(&doc)
		anchor_doc(t, &doc, "abcdefgh")
	}
}

// test_anchor_replace_cases pins the replace rules, including the
// range-end case that stays adjacent to the following text.
@(test)
test_anchor_replace_cases :: proc(t: ^testing.T) {
	// Replace [2,5) ("cde") with "XY" (2 bytes).
	cases := []struct {
		pos:      int,
		affinity: txn.Affinity,
		want:     int,
	} {
		{1, .Left, 1},
		{2, .Left, 4},
		{2, .Right, 2},
		{4, .Left, 4},
		{4, .Right, 2},
		{5, .Left, 4},
		{5, .Right, 4},
		{7, .Left, 6},
		{7, .Right, 6},
	}
	for c, i in cases {
		doc: txn.Doc
		anchor_doc(t, &doc, "abcdefgh")
		a, err := txn.anchor_at(&doc, c.pos, c.affinity)
		testing.expect(t, errs.ok(err))
		apply_edits(t, &doc, {replace_op(2, 5, "XY")})
		expect_anchor(t, &doc, &a, c.want, fmt.tprintf("replace case %v", i))
		txn.doc_destroy(&doc)
	}

	// Empty-range replace behaves as a pure insert.
	doc: txn.Doc
	anchor_doc(t, &doc, "abcdefgh")
	a, aerr := txn.anchor_at(&doc, 3, .Left)
	testing.expect(t, errs.ok(aerr))
	b, berr2 := txn.anchor_at(&doc, 3, .Right)
	testing.expect(t, errs.ok(berr2))
	apply_edits(t, &doc, {replace_op(3, 3, "Q")})
	expect_anchor(t, &doc, &a, 4, "empty replace, left")
	expect_anchor(t, &doc, &b, 3, "empty replace, right")
	txn.doc_destroy(&doc)
}

// test_anchor_through_log pins replay from a captured revision across
// several transactions.
@(test)
test_anchor_through_log :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	// Capture at revision 0 (empty document).
	a, err := txn.anchor_at(&doc, 0, .Left)
	testing.expect(t, errs.ok(err))

	apply_edits(t, &doc, {insert_op(0, "hello")}) // rev 1
	b, berr := txn.anchor_at(&doc, 1, .Right)
	testing.expect(t, errs.ok(berr))

	apply_edits(t, &doc, {insert_op(2, "X")}) // rev 2
	c, cerr := txn.anchor_at(&doc, 6, .Left)
	testing.expect(t, errs.ok(cerr))

	apply_edits(t, &doc, {delete_op(1, 3)}) // rev 3: "hllo"

	expect_anchor(t, &doc, &a, 4, "anchor from rev 0") // pushed by all edits
	expect_anchor(t, &doc, &b, 1, "anchor from rev 1") // stuck to 'h'
	expect_anchor(t, &doc, &c, 4, "anchor from rev 2")

	// Transform again: already at the current revision — a no-op.
	expect_anchor(t, &doc, &a, 4, "idempotent transform")

	// An anchor from a revision that does not exist here is invalid.
	future: txn.Anchor
	future = {pos = 0, affinity = .Left, revision = txn.doc_revision(&doc) + 1}
	ferr := txn.anchor_transform(&doc, &future)
	testing.expect(t, ferr.kind == .Invalid_Input)
	errs.destroy(&ferr)
}

// ref_anchor_apply is the independent reference transform (same
// policy, different code shape).
ref_anchor_apply :: proc(pos: ^int, affinity: txn.Affinity, op: txn.Operation) {
	switch o in op {
	case txn.Insert:
		l := len(o.data)
		if pos^ > o.pos || (pos^ == o.pos && affinity == .Left) {
			pos^ += l
		}
	case txn.Delete:
		lo, hi := o.range.start, o.range.end
		if pos^ > lo {
			if pos^ >= hi {
				pos^ -= hi - lo
			} else {
				pos^ = lo
			}
		}
	case txn.Replace:
		lo, hi, l := o.range.start, o.range.end, len(o.data)
		if hi <= lo {
			// An empty range is a pure insert at lo: affinity applies.
			if pos^ > lo || (pos^ == lo && affinity == .Left) {
				pos^ += l
			}
		} else if pos^ < lo {
			// untouched
		} else if pos^ == hi {
			pos^ = lo + l
		} else if pos^ == lo {
			if affinity == .Left {
				pos^ += l
			}
		} else if pos^ < hi {
			pos^ = lo
			if affinity == .Left {
				pos^ += l
			}
		} else {
			pos^ = pos^ - (hi - lo) + l
		}
	}
}

// Ref_Entry records one transaction for the reference replay.
Ref_Entry :: struct {
	base: u64,
	ops:  []txn.Operation,
}

// Tracked_Anchor pairs an anchor with the affinity used at capture
// (the anchor's affinity field is part of the transform, so keep both
// for clarity in the reference comparison).
Tracked_Anchor :: struct {
	anchor:   txn.Anchor,
	affinity: txn.Affinity,
}

// test_anchor_randomized_differential mutates the document randomly
// and checks a pool of anchors (captured at random revisions and
// positions) against the independent reference transform after every
// transaction.
@(test)
test_anchor_randomized_differential :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 5, target_leaf_bytes = 24})))
	defer txn.doc_destroy(&doc)

	alphabet := bytes_of("ab\r\né€😀z中✓")
	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)
	ref_log := make([dynamic]Ref_Entry, context.allocator)
	defer {
		for e in ref_log {
			txn.ops_destroy(e.ops)
		}
		delete(ref_log)
	}
	tracked := make([dynamic]Tracked_Anchor, context.allocator)
	defer delete(tracked)

	state: u64 = 0x9e37_79b9_7f4a_7c15
	next := proc(x: ^u64) -> u64 {
		v := x^
		v ~= v << 13
		v ~= v >> 7
		v ~= v << 17
		x^ = v
		return v
	}

	// (Tracked_Anchor is declared at package scope.)

	for step in 0 ..< 400 {
		// Build one transaction of 1..4 non-overlapping ops.
		ops := make([dynamic]txn.Operation, context.allocator)
		n_ops := int(next(&state) % 4) + 1
		attempts := 0
		for len(ops) < n_ops && attempts < 12 {
			attempts += 1
			kind := next(&state) % 3
			op: txn.Operation
			if kind == 0 || len(ref) == 0 {
				pos := int(next(&state) % u64(len(ref) + 1))
				data := make([]u8, int(next(&state) % 25), context.allocator)
				for &b in data {
					b = alphabet[int(next(&state) % u64(len(alphabet)))]
				}
				op = txn.Operation(txn.Insert{pos = pos, data = data})
			} else if kind == 1 {
				lo := int(next(&state) % u64(len(ref)))
				hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
				op = txn.Operation(txn.Delete{range = {lo, hi}})
			} else {
				lo := int(next(&state) % u64(len(ref)))
				hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
				data := make([]u8, int(next(&state) % 15), context.allocator)
				for &b in data {
					b = alphabet[int(next(&state) % u64(len(alphabet)))]
				}
				op = txn.Operation(txn.Replace{range = {lo, hi}, data = data})
			}
			if !ref_overlaps(op, ops[:]) {
				append(&ops, op)
			} else {
				switch o in op {
				case txn.Insert:
					delete(o.data, context.allocator)
				case txn.Replace:
					delete(o.data, context.allocator)
				case txn.Delete:
				}
			}
		}

		tr: txn.Transaction
		tr = {source = .Edit, base_revision = txn.doc_revision(&doc), ops = ops[:]}
		testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

		// Reference: content + history + anchor transform. The
		// reference log stores the ops in the applied (sorted) order —
		// the same order the doc replays.
		if len(ops) > 0 {
			ref_apply(&ref, ops[:])
		}
		copied, cerr := txn.ops_copy(ops[:])
		testing.expect(t, errs.ok(cerr))
		ref_sort(copied)
		append(&ref_log, Ref_Entry{base = tr.base_revision, ops = copied})
		for op in ops {
			switch o in op {
			case txn.Insert:
				delete(o.data, context.allocator)
			case txn.Replace:
				delete(o.data, context.allocator)
			case txn.Delete:
			}
		}
		delete(ops)

		// Capture a fresh anchor every 3rd step.
		if step % 3 == 0 {
			affinity := txn.Affinity(next(&state) % 2)
			pos := 0
			if len(ref) > 0 {
				pos = int(next(&state) % u64(len(ref) + 1))
			}
			a, aerr := txn.anchor_at(&doc, pos, affinity)
			testing.expect(t, errs.ok(aerr))
			append(&tracked, Tracked_Anchor{anchor = a, affinity = affinity})
		}

		// Transform every tracked anchor through both implementations.
		for i in 0 ..< len(tracked) {
			start_pos := tracked[i].anchor.pos
			start_rev := tracked[i].anchor.revision

			txerr := txn.anchor_transform(&doc, &tracked[i].anchor)
			testing.expect(t, errs.ok(txerr))

			ref_pos := start_pos
			ref_anchor_transform(ref_log[:], &ref_pos, tracked[i].affinity, start_rev)
			testing.expectf(
				t,
				tracked[i].anchor.pos == ref_pos,
				"anchor %v at step %v: doc %v, ref %v",
				i,
				step,
				tracked[i].anchor.pos,
				ref_pos,
			)
			testing.expect(t, tracked[i].anchor.revision == txn.doc_revision(&doc))
		}

		if step % 10 == 0 {
			got := doc_flatten(t, &doc)
			testing.expectf(t, bytes.equal(got, ref[:]), "content at step %v", step)
			delete(got)
			expect_doc_ok(t, &doc, fmt.tprintf("step %v", step))
		}
	}
}

// ref_anchor_transform replays the reference history for an anchor
// captured at `from_rev` (independent replay loop).
ref_anchor_transform :: proc(
	ref_log: []Ref_Entry,
	pos: ^int,
	affinity: txn.Affinity,
	from_rev: u64,
) {
	for e in ref_log {
		if e.base < from_rev {
			continue
		}
		for op in e.ops {
			ref_anchor_apply(pos, affinity, op)
		}
	}
}
