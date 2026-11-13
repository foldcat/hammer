// Tests for the transaction layer (M02.05): `hammer:core/txn` —
// apply semantics against a reference model, deterministic
// original-snapshot ordering, stale-base rejection, validation,
// atomic rollback, the log chain, and a randomized differential.
package txn_test

import "core:bytes"
import "core:fmt"
import "core:testing"
import mem_virtual "core:mem/virtual"

import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

// insert_op / delete_op / replace_op build operations.
insert_op :: proc(pos: int, data: string) -> txn.Operation {
	return txn.Operation(txn.Insert{pos = pos, data = bytes_of(data)})
}
delete_op :: proc(start, end: int) -> txn.Operation {
	return txn.Operation(txn.Delete{range = rope.Byte_Range{start, end}})
}
replace_op :: proc(start, end: int, data: string) -> txn.Operation {
	return txn.Operation(txn.Replace{range = rope.Byte_Range{start, end}, data = bytes_of(data)})
}

// bytes_of converts a string to a byte slice (repo idiom for literals).
bytes_of :: proc(text: string) -> []byte {
	return transmute([]byte)text
}

// doc_flatten returns the whole document content (caller deletes).
doc_flatten :: proc(t: ^testing.T, doc: ^txn.Doc) -> []byte {
	got, err := rope.tree_read_all(&doc.tree, rope.Byte_Range{0, rope.tree_byte_count(&doc.tree)})
	testing.expect(t, errs.ok(err), "flatten must not fail")
	return got
}

// expect_doc_ok runs the document invariant checker.
expect_doc_ok :: proc(t: ^testing.T, doc: ^txn.Doc, what: string) {
	cerr := txn.doc_check(doc)
	if !errs.ok(cerr) {
		desc := errs.describe(cerr, context.allocator)
		defer delete(desc, context.allocator)
		errs.destroy(&cerr)
		testing.expectf(t, false, "%s: %s", what, desc)
	}
}

// test_apply_basic pins single-op transactions: content, revision,
// ids, and the log chain.
@(test)
test_apply_basic :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	testing.expect(t, txn.doc_revision(&doc) == 0)
	testing.expect(t, txn.doc_log_len(&doc) == 0)

	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)
	states := make([dynamic][]u8, context.allocator) // content after each txn
	defer {
		for s in states {
			delete(s, context.allocator)
		}
		delete(states)
	}
	append(&states, bytes.clone({}, context.allocator))

	// Typing: "hello".
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = txn.doc_revision(&doc), ops = {insert_op(0, "hello")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	testing.expect(t, tr.id == 1)
	testing.expect(t, txn.doc_revision(&doc) == 1)
	inject_at_elems(&ref, 0, ..bytes_of("hello"))
	append(&states, bytes.clone(ref[:], context.allocator))

	// Paste: append " world".
	tr = {source = .Paste, base_revision = txn.doc_revision(&doc), ops = {insert_op(len(ref), " world")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	testing.expect(t, tr.id == 2)
	inject_at_elems(&ref, len(ref), ..bytes_of(" world"))
	append(&states, bytes.clone(ref[:], context.allocator))

	// Edit: replace "world" with "there".
	tr = {source = .Edit, base_revision = txn.doc_revision(&doc), ops = {replace_op(6, 11, "there")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	testing.expect(t, tr.id == 3)
	remove_range(&ref, 6, 11)
	inject_at_elems(&ref, 6, ..bytes_of("there"))
	append(&states, bytes.clone(ref[:], context.allocator))

	// Cut: delete "hello".
	tr = {source = .Cut, base_revision = txn.doc_revision(&doc), ops = {delete_op(0, 5)}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	testing.expect(t, tr.id == 4)
	remove_range(&ref, 0, 5)
	append(&states, bytes.clone(ref[:], context.allocator))

	got := doc_flatten(t, &doc)
	defer delete(got)
	testing.expect(t, bytes.equal(got, ref[:]), "content must match the reference")
	testing.expect(t, txn.doc_revision(&doc) == 4)
	expect_doc_ok(t, &doc, "after basic applies")

	// The log's snapshot roots must reproduce each state.
	for entry, i in doc.log {
		before, berr := rope.tree_read_root_all(&doc.tree, entry.before_root, rope.Byte_Range{0, len(states[i])})
		testing.expect(t, errs.ok(berr))
		testing.expectf(t, bytes.equal(before, states[i]), "before_root of entry %v must be the pre-transaction state", i)
		delete(before)

		after, aerr := rope.tree_read_root_all(&doc.tree, entry.after_root, rope.Byte_Range{0, len(states[i + 1])})
		testing.expect(t, errs.ok(aerr))
		testing.expectf(t, bytes.equal(after, states[i + 1]), "after_root of entry %v must be the post-transaction state", i)
		delete(after)
	}
}

// test_stale_rejection pins the revisioned-result contract: a stale
// base revision is .Conflict and changes nothing.
@(test)
test_stale_rejection :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {})))
	defer txn.doc_destroy(&doc)

	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "abc")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

	before := doc_flatten(t, &doc)
	defer delete(before)

	// Stale: computed against revision 0 but the doc is at 1.
	stale: txn.Transaction
	stale = {source = .Typing, base_revision = 0, ops = {insert_op(1, "X")}}
	err := txn.doc_apply(&doc, &stale)
	testing.expect(t, err.kind == .Conflict, "stale base must be .Conflict")
	errs.destroy(&err)

	after := doc_flatten(t, &doc)
	defer delete(after)
	testing.expect(t, bytes.equal(after, before), "stale apply must not change content")
	testing.expect(t, txn.doc_revision(&doc) == 1)
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	expect_doc_ok(t, &doc, "after stale rejection")
}

// test_multi_op_ordering pins the original-snapshot contract: the same
// operations produce the same content in any input order.
@(test)
test_multi_op_ordering :: proc(t: ^testing.T) {
	// Seed content "0123456789abcdefghij" (20 bytes).
	seed := "0123456789abcdefghij"
	orders := [][]txn.Operation {
		{
			insert_op(5, "XX"),
			delete_op(10, 15),
			replace_op(2, 4, "YY"),
			insert_op(20, "ZZ"),
		},
		{
			insert_op(20, "ZZ"),
			replace_op(2, 4, "YY"),
			delete_op(10, 15),
			insert_op(5, "XX"),
		},
		{
			replace_op(2, 4, "YY"),
			insert_op(5, "XX"),
			insert_op(20, "ZZ"),
			delete_op(10, 15),
		},
		{
			delete_op(10, 15),
			insert_op(5, "XX"),
			insert_op(20, "ZZ"),
			replace_op(2, 4, "YY"),
		},
	}

	// The deterministic application order: insert@20 first (original
	// end), then delete[10,15), then insert@5, then replace[2,4).
	want := make([dynamic]u8, context.allocator)
	defer delete(want)
	append(&want, ..bytes_of(seed))
	inject_at_elems(&want, 20, ..bytes_of("ZZ")) // insert at the end
	remove_range(&want, 10, 15) // delete
	inject_at_elems(&want, 5, ..bytes_of("XX")) // insert at 5
	remove_range(&want, 2, 4) // the replace's delete
	inject_at_elems(&want, 2, ..bytes_of("YY")) // the replace's insert

	for ops, i in orders {
		doc: txn.Doc
		testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 3})))
		defer txn.doc_destroy(&doc)

		seed_tr: txn.Transaction
		seed_tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, seed)}}
		testing.expect(t, errs.ok(txn.doc_apply(&doc, &seed_tr)))

		tr: txn.Transaction
		tr = {source = .Edit, base_revision = 1, ops = ops}
		testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

		got := doc_flatten(t, &doc)
		testing.expectf(t, bytes.equal(got, want[:]), "order %v must produce the same content", i)
		delete(got)
		expect_doc_ok(t, &doc, fmt.tprintf("order %v", i))
	}
}

// test_validation pins the operation checks: bounds, overlaps, and
// duplicate insert positions are .Invalid_Input with no mutation.
@(test)
test_validation :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {})))
	defer txn.doc_destroy(&doc)

	seed_tr: txn.Transaction
	seed_tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "0123456789")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &seed_tr)))
	before := doc_flatten(t, &doc)
	defer delete(before)

	bad := [][]txn.Operation {
		{insert_op(11, "x")},
		{delete_op(3, 12)},
		{delete_op(5, 9), delete_op(8, 10)}, // overlapping ranges
		{insert_op(3, "x"), insert_op(3, "y")}, // duplicate positions
		{delete_op(2, 8), insert_op(5, "x")}, // insert inside a range
		{replace_op(0, 4, "a"), replace_op(2, 6, "b")}, // overlapping replaces
	}
	for ops, i in bad {
		tr: txn.Transaction
		tr = {source = .Edit, base_revision = 1, ops = ops}
		err := txn.doc_apply(&doc, &tr)
		testing.expectf(t, err.kind == .Invalid_Input, "case %v must be rejected", i)
		errs.destroy(&err)
		testing.expect(t, txn.doc_revision(&doc) == 1, "rejected ops must not bump the revision")
	}
	after := doc_flatten(t, &doc)
	defer delete(after)
	testing.expect(t, bytes.equal(after, before), "rejected ops must not change content")
	expect_doc_ok(t, &doc, "after validation rejections")

	// Empty ops and empty inserts are no-ops.
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 1, ops = {}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	tr = {source = .Typing, base_revision = 1, ops = {insert_op(0, "")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	testing.expect(t, txn.doc_revision(&doc) == 1)
	testing.expect(t, txn.doc_log_len(&doc) == 1)
}

// test_rollback_on_log_failure pins the all-or-nothing apply: when the
// log copy cannot be allocated, the document rolls back completely.
@(test)
test_rollback_on_log_failure :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {})))
	defer txn.doc_destroy(&doc)

	seed_tr: txn.Transaction
	seed_tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "seed")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &seed_tr)))
	before := doc_flatten(t, &doc)
	defer delete(before)

	// A fixed arena large enough for the apply scratch (sorted list,
	// chunk/piece lists) but too small for the data copy: the log
	// copy must fail and the apply must roll back.
	buf := make([]byte, 4 * 1024)
	defer delete(buf)
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_buffer(&arena, buf) == nil)
	defer mem_virtual.arena_destroy(&arena)
	alloc := mem_virtual.arena_allocator(&arena)

	big := make([]byte, 32 * 1024, context.allocator)
	defer delete(big, context.allocator)
	tr: txn.Transaction
	tr = {source = .Paste, base_revision = 1, ops = {txn.Operation(txn.Insert{pos = 4, data = big})}}
	err := txn.doc_apply(&doc, &tr, alloc)
	testing.expect(t, err.kind == .Resource_Limit, "log copy failure must be .Resource_Limit")
	errs.destroy(&err)

	after := doc_flatten(t, &doc)
	defer delete(after)
	testing.expect(t, bytes.equal(after, before), "failed apply must roll back content")
	testing.expect(t, txn.doc_revision(&doc) == 1)
	testing.expect(t, txn.doc_log_len(&doc) == 1)
	expect_doc_ok(t, &doc, "after rollback")
}

// ref_sort orders operations in the deterministic application order
// (descending start; ranges before inserts at equal starts) — the
// reference's own implementation of the ordering contract.
ref_sort :: proc(ops: []txn.Operation) {
	for i := 1; i < len(ops); i += 1 {
		v := ops[i]
		j := i - 1
		for j >= 0 {
			a, b := v, ops[j]
			a_start, b_start := ref_op_start(a), ref_op_start(b)
			less := a_start > b_start ||
				(a_start == b_start && ref_op_is_range(a) && !ref_op_is_range(b))
			if !less {
				break
			}
			ops[j + 1] = ops[j]
			j -= 1
		}
		ops[j + 1] = v
	}
}

// ref_apply applies operations to the reference model in the same
// deterministic order as doc_apply (independent implementation).
ref_apply :: proc(ref: ^[dynamic]u8, ops: []txn.Operation) {
	sorted := make([]txn.Operation, len(ops), context.allocator)
	defer delete(sorted)
	copy(sorted, ops)
	ref_sort(sorted)
	for op in sorted {
		switch o in op {
		case txn.Insert:
			if len(o.data) > 0 {
				ok, _ := inject_at_elems(ref, o.pos, ..o.data)
				assert(ok)
			}
		case txn.Delete:
			if o.range.start < o.range.end {
				remove_range(ref, o.range.start, o.range.end)
			}
		case txn.Replace:
			if o.range.start < o.range.end {
				remove_range(ref, o.range.start, o.range.end)
			}
			if len(o.data) > 0 {
				ok, _ := inject_at_elems(ref, o.range.start, ..o.data)
				assert(ok)
			}
		}
	}
}

ref_op_start :: proc(op: txn.Operation) -> int {
	switch o in op {
	case txn.Insert:
		return o.pos
	case txn.Delete:
		return o.range.start
	case txn.Replace:
		return o.range.start
	}
	return 0
}

ref_op_is_range :: proc(op: txn.Operation) -> bool {
	switch o in op {
	case txn.Insert:
		return false
	case txn.Delete, txn.Replace:
		return true
	}
	return false
}

// ref_overlaps checks a candidate operation against the ops already
// picked for one transaction (the validation rules, replicated).
ref_overlaps :: proc(op: txn.Operation, picked: []txn.Operation) -> bool {
	for other in picked {
		a_range := ref_op_is_range(op)
		b_range := ref_op_is_range(other)
		if a_range && b_range {
			ar := ref_op_range(op)
			br := ref_op_range(other)
			if max(ar.start, br.start) < min(ar.end, br.end) {
				return true
			}
		} else if a_range {
			ar := ref_op_range(op)
			p := ref_op_start(other)
			if p > ar.start && p < ar.end {
				return true
			}
		} else if b_range {
			br := ref_op_range(other)
			p := ref_op_start(op)
			if p > br.start && p < br.end {
				return true
			}
		} else if ref_op_start(op) == ref_op_start(other) {
			return true
		}
	}
	return false
}

ref_op_range :: proc(op: txn.Operation) -> rope.Byte_Range {
	switch o in op {
	case txn.Insert:
		return {}
	case txn.Delete:
		return o.range
	case txn.Replace:
		return o.range
	}
	return {}
}

// test_randomized_differential drives random transactions against the
// reference model, plus periodic stale-base probes.
@(test)
test_randomized_differential :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 5, target_leaf_bytes = 24})))
	defer txn.doc_destroy(&doc)

	alphabet := bytes_of("ab\r\né€😀z中✓")
	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)

	state: u64 = 0x9e37_79b9_7f4a_7c15
	next := proc(x: ^u64) -> u64 {
		v := x^
		v ~= v << 13
		v ~= v >> 7
		v ~= v << 17
		x^ = v
		return v
	}

	for step in 0 ..< 400 {
		// A transaction of 1..4 valid (non-overlapping) random ops in
		// base-snapshot coordinates.
		ops := make([dynamic]txn.Operation, context.allocator)
		n_ops := int(next(&state) % 4) + 1
		attempts := 0
		for len(ops) < n_ops && attempts < 12 {
			attempts += 1
			kind := next(&state) % 3
			op: txn.Operation
			if kind == 0 || len(ref) == 0 {
				pos := int(next(&state) % u64(len(ref) + 1))
				plen := int(next(&state) % 25)
				data := make([]u8, plen, context.allocator)
				for &b in data {
					b = alphabet[int(next(&state) % u64(len(alphabet)))]
				}
				op = txn.Operation(txn.Insert{pos = pos, data = data})
			} else if kind == 1 {
				lo := int(next(&state) % u64(len(ref)))
				hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
				op = txn.Operation(txn.Delete{range = rope.Byte_Range{lo, hi}})
			} else {
				lo := int(next(&state) % u64(len(ref)))
				hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
				plen := int(next(&state) % 15)
				data := make([]u8, plen, context.allocator)
				for &b in data {
					b = alphabet[int(next(&state) % u64(len(alphabet)))]
				}
				op = txn.Operation(txn.Replace{range = rope.Byte_Range{lo, hi}, data = data})
			}
			if !ref_overlaps(op, ops[:]) {
				append(&ops, op)
			} else {
				// Free the candidate's data.
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
		err := txn.doc_apply(&doc, &tr)
		testing.expect(t, errs.ok(err), "apply must not fail")
		if len(ops) > 0 {
			ref_apply(&ref, ops[:])
		}
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

		if step % 10 == 0 {
			got := doc_flatten(t, &doc)
			testing.expectf(t, bytes.equal(got, ref[:]), "content at step %v", step)
			delete(got)
			expect_doc_ok(t, &doc, fmt.tprintf("step %v", step))
		}

		if step % 7 == 0 && txn.doc_revision(&doc) > 2 {
			// Stale probe: an old base revision must be rejected.
			stale: txn.Transaction
			stale = {source = .Typing, base_revision = txn.doc_revision(&doc) - 2, ops = {insert_op(0, "STALE")}}
			serr := txn.doc_apply(&doc, &stale)
			testing.expect(t, serr.kind == .Conflict, "stale probe must conflict")
			errs.destroy(&serr)
			got := doc_flatten(t, &doc)
			testing.expect(t, bytes.equal(got, ref[:]), "stale probe must not change content")
			delete(got)
		}
	}

	got := doc_flatten(t, &doc)
	defer delete(got)
	testing.expect(t, bytes.equal(got, ref[:]), "final content")
	expect_doc_ok(t, &doc, "final")
}
