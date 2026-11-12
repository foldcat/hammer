// Tests for the persistent rope tree (M02.03): build/insert/delete
// semantics against a reference byte model, copy-on-write snapshot
// persistence, balancing invariants (node bounds, uniform leaf depth,
// exact metrics), validation errors, split/merge cascades, and a
// randomized differential property with an independent counting
// oracle.
package rope_test

import "core:bytes"
import "core:fmt"
import "core:testing"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import rope "hammer:core/rope"

// tree_append_text appends text to a tree, expecting success.
tree_append_text :: proc(t: ^testing.T, tree: ^rope.Tree, text: string) {
	err := rope.tree_append(tree, bytes_of(text))
	if !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		defer delete(desc, context.allocator)
		errs.destroy(&err)
		testing.expectf(t, false, "tree append(%q) failed: %s", text, desc)
	}
}

// tree_flatten returns the whole tree content (caller deletes).
tree_flatten :: proc(t: ^testing.T, tree: ^rope.Tree) -> []byte {
	got, err := rope.tree_read_all(tree, rope.Byte_Range{0, rope.tree_byte_count(tree)})
	testing.expect(t, errs.ok(err), "flatten must not fail")
	return got
}

// expect_tree_ok runs the full invariant checker.
expect_tree_ok :: proc(t: ^testing.T, tree: ^rope.Tree, what: string) {
	cerr := rope.tree_check(tree)
	if !errs.ok(cerr) {
		desc := errs.describe(cerr, context.allocator)
		defer delete(desc, context.allocator)
		errs.destroy(&cerr)
		testing.expectf(t, false, "%s: tree invariant violated: %s", what, desc)
	}
}

// test_tree_build_append builds a tree by appending (including an
// empty append) and checks content, metrics, revision, and shape.
@(test)
test_tree_build_append :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 8})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	testing.expect(t, rope.tree_byte_count(&tree) == 0)
	testing.expect(t, rope.tree_revision(&tree) == 0)
	testing.expect(t, rope.tree_height(&tree) == 0)
	expect_tree_ok(t, &tree, "empty tree")

	tree_append_text(t, &tree, "hello ")
	tree_append_text(t, &tree, "")
	tree_append_text(t, &tree, "wörld\r\nsecond line\n")

	ref := "hello wörld\r\nsecond line\n"
	testing.expect(t, rope.tree_revision(&tree) == 2, "empty append must not bump the revision")
	testing.expect(t, rope.tree_byte_count(&tree) == len(ref))
	testing.expect(t, rope.tree_height(&tree) == 1)
	testing.expect(t, rope.tree_leaf_count(&tree) == 1)
	expect_metrics(t, rope.tree_metrics(&tree), rope.metrics_of(bytes_of(ref)), "tree metrics")
	expect_tree_ok(t, &tree, "after appends")

	got := tree_flatten(t, &tree)
	defer delete(got)
	testing.expect(t, bytes.equal(got, bytes_of(ref)), "flatten must reproduce the input")
}

// test_tree_insert_positions inserts at the start, mid-piece, piece
// boundary, and end, checking content against the reference model.
@(test)
test_tree_insert_positions :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 3})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "abcdefghij") // pieces: abc def ghi j

	// Reference model via inject_at.
	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)
	append(&ref, ..bytes_of("abcdefghij"))

	texts := []string{"XX", "é€", "Q", "!!!!"}
	for step in 0 ..< 4 {
		positions := []int{0, 1, 4, 7, 10}
		pos := positions[step % len(positions)]
		text := texts[step]
		err := rope.tree_insert(&tree, pos, bytes_of(text))
		testing.expect(t, errs.ok(err))
		ok, _ := inject_at_elems(&ref, pos, ..bytes_of(text))
		testing.expect(t, ok)

		got := tree_flatten(t, &tree)
		testing.expectf(t, bytes.equal(got, ref[:]), "insert at %v must match the reference", pos)
		delete(got)
		expect_tree_ok(t, &tree, fmt.tprintf("after insert at %v", pos))
	}
}

// test_tree_delete_ranges deletes prefix, middle, suffix, mid-piece
// ranges, and the whole content, checking against the reference model.
@(test)
test_tree_delete_ranges :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 3})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "abcdefghijklmnop")

	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)
	append(&ref, ..bytes_of("abcdefghijklmnop"))

	// Ranges valid against the shrinking content at each step: 16 ->
	// 14 -> 8 -> 5 -> 4 -> 4 -> 0 bytes. Includes prefix, middle,
	// suffix-ish, mid-piece, empty, and full deletes.
	ranges := []rope.Byte_Range{{0, 2}, {5, 11}, {3, 6}, {0, 1}, {0, 0}, {0, 4}}
	rev := rope.tree_revision(&tree)
	for r, i in ranges {
		err := rope.tree_delete(&tree, r)
		testing.expect(t, errs.ok(err))
		if r.start != r.end {
			remove_range(&ref, r.start, r.end)
			rev += 1
		}
		testing.expectf(t, rope.tree_revision(&tree) == rev, "revision after delete %v", i)

		got := tree_flatten(t, &tree)
		testing.expectf(t, bytes.equal(got, ref[:]), "delete %v must match the reference", r)
		delete(got)
		expect_tree_ok(t, &tree, fmt.tprintf("after delete %v", r))
	}

	// Delete everything: the tree becomes empty.
	err := rope.tree_delete(&tree, rope.Byte_Range{0, rope.tree_byte_count(&tree)})
	testing.expect(t, errs.ok(err))
	testing.expect(t, rope.tree_byte_count(&tree) == 0)
	testing.expect(t, rope.tree_height(&tree) == 0)
	expect_tree_ok(t, &tree, "after full delete")
}

// test_tree_delete_splits_full_leaf forces the MAX+1 survivor case: a
// delete inside one piece of a full leaf must split the leaf.
@(test)
test_tree_delete_splits_full_leaf :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 4})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree)

	// 32 bytes -> 8 pieces of 4 bytes -> one full leaf.
	tree_append_text(t, &tree, "01234567890123456789012345678901")
	testing.expect(t, rope.tree_leaf_count(&tree) == 1)
	testing.expect(t, rope.tree_leaf_count(&tree) == 1)

	// Delete [1,3): splits piece 0 into [0,1) and [3,4) -> 9 survivors
	// -> the leaf must split into two.
	err := rope.tree_delete(&tree, rope.Byte_Range{1, 3})
	testing.expect(t, errs.ok(err))
	expect_tree_ok(t, &tree, "after full-leaf mid-piece delete")
	testing.expect(t, rope.tree_leaf_count(&tree) == 2)

	got := tree_flatten(t, &tree)
	defer delete(got)
	testing.expect(t, bytes.equal(got, bytes_of("034567890123456789012345678901")), "content after split delete")
}

// test_tree_insert_splits_full_leaf inserts into a full leaf and
// checks the cascade keeps the tree valid.
@(test)
test_tree_insert_splits_full_leaf :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 4})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "01234567890123456789012345678901") // one full leaf
	err := rope.tree_insert(&tree, 1, bytes_of("HELLO"))
	testing.expect(t, errs.ok(err))
	expect_tree_ok(t, &tree, "after full-leaf insert")
	testing.expect(t, rope.tree_leaf_count(&tree) >= 2)

	got := tree_flatten(t, &tree)
	defer delete(got)
	testing.expect(t, bytes.equal(got, bytes_of("0HELLO1234567890123456789012345678901")), "content after split insert")
}

// test_tree_snapshot_persistence pins the copy-on-write contract:
// captured roots stay byte-identical across later edits.
@(test)
test_tree_snapshot_persistence :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 3})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "the quick brown fox jumps over the lazy dog")

	root_v1 := tree.root
	content_v1 := tree_flatten(t, &tree)
	defer delete(content_v1)

	tree_append_text(t, &tree, " — extended")
	err := rope.tree_insert(&tree, 4, bytes_of("NOT-"))
	testing.expect(t, errs.ok(err))
	err = rope.tree_delete(&tree, rope.Byte_Range{10, 15})
	testing.expect(t, errs.ok(err))

	// The v1 root must still produce the v1 content byte-identically.
	old, oerr := rope.tree_read_root_all(&tree, root_v1, rope.Byte_Range{0, len(content_v1)})
	defer delete(old)
	testing.expect(t, errs.ok(oerr))
	testing.expect(t, bytes.equal(old, content_v1), "snapshot must stay byte-identical after edits")

	// And again after more edits, including range reads from the old
	// root and metric checks against the old root.
	tree_append_text(t, &tree, " more")
	old2, oerr2 := rope.tree_read_root_all(&tree, root_v1, rope.Byte_Range{0, len(content_v1)})
	defer delete(old2)
	testing.expect(t, errs.ok(oerr2))
	testing.expect(t, bytes.equal(old2, content_v1), "snapshot must survive repeated edits")

	// The current tree is different from the snapshot.
	now := tree_flatten(t, &tree)
	defer delete(now)
	testing.expect(t, !bytes.equal(now, content_v1), "the live tree must reflect the edits")
	expect_tree_ok(t, &tree, "live tree after snapshot edits")
}

// test_tree_errors pins the validation behavior: bad offsets/ranges
// are .Invalid_Input and leave the tree untouched.
@(test)
test_tree_errors :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 4})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "hello")
	rev := rope.tree_revision(&tree)
	before := tree_flatten(t, &tree)
	defer delete(before)

	err := rope.tree_insert(&tree, -1, bytes_of("x"))
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	err = rope.tree_insert(&tree, 6, bytes_of("x"))
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	err = rope.tree_delete(&tree, rope.Byte_Range{3, 9})
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	err = rope.tree_delete(&tree, rope.Byte_Range{-1, 2})
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)

	testing.expect(t, rope.tree_revision(&tree) == rev, "failed ops must not bump the revision")
	after := tree_flatten(t, &tree)
	defer delete(after)
	testing.expect(t, bytes.equal(after, before), "failed ops must not change content")
}

// test_tree_randomized_differential is the M02.03 differential
// property: seeded random inserts/appends/deletes checked against a
// reference byte model after every operation — content, metrics (vs
// both metrics_of and the independent oracle), tree invariants, and
// revision accounting — plus periodic span-iteration checks and
// snapshot persistence probes.
@(test)
test_tree_randomized_differential :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 5})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 24})))
	defer rope.tree_destroy(&tree)

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

	rev := u64(0)
	for step in 0 ..< 500 {
		op := next(&state) % 3

		if op == 0 || op == 1 {
			// Insert or append.
			piece := make([]u8, int(next(&state) % 30), context.allocator)
			for &b in piece {
				b = alphabet[int(next(&state) % u64(len(alphabet)))]
			}
			pos := 0
			if op == 0 {
				pos = int(next(&state) % u64(len(ref) + 1))
			} else {
				pos = len(ref)
			}
			err := rope.tree_insert(&tree, pos, piece)
			testing.expect(t, errs.ok(err), "insert must not fail")
			if len(piece) > 0 {
				ok, _ := inject_at_elems(&ref, pos, ..piece)
				testing.expect(t, ok)
				rev += 1
			}
			delete(piece, context.allocator)
		} else {
			// Delete.
			if len(ref) == 0 {
				continue
			}
			lo := int(next(&state) % u64(len(ref)))
			hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
			err := rope.tree_delete(&tree, rope.Byte_Range{lo, hi})
			testing.expect(t, errs.ok(err), "delete must not fail")
			if hi > lo {
				remove_range(&ref, lo, hi)
				rev += 1
			}
		}

		testing.expectf(t, rope.tree_revision(&tree) == rev, "revision at step %v", step)
		testing.expectf(t, rope.tree_byte_count(&tree) == len(ref), "byte count at step %v", step)
		expect_tree_ok(t, &tree, fmt.tprintf("step %v", step))

		got := tree_flatten(t, &tree)
		testing.expectf(t, bytes.equal(got, ref[:]), "content at step %v", step)
		delete(got)

		expect_metrics(t, rope.tree_metrics(&tree), rope.metrics_of(ref[:]), fmt.tprintf("metrics at step %v", step))
		om := oracle_metrics(ref[:])
		m := rope.tree_metrics(&tree)
		testing.expectf(
			t,
			m.byte_count == om.byte_count && m.scalar_count == om.scalar_count &&
			m.lf_count == om.lf_count && m.lone_cr_count == om.lone_cr_count,
			fmt.tprintf("oracle mismatch at step %v: tree %v vs oracle %v", step, m, om),
		)

		if step % 10 == 0 && len(ref) > 0 {
			// Span iteration over a random range.
			start := int(next(&state) % u64(len(ref) + 1))
			end := start + int(next(&state) % u64(len(ref) - start + 1))
			spans := make([dynamic]u8, context.allocator)
			it: rope.Tree_Span_Iter
			testing.expect(t, errs.ok(rope.tree_span_iter_init(&it, tree.root, rope.Byte_Range{start, end})))
			for {
				span, more := rope.tree_span_iter_next(&it, &tree)
				if !more {
					break
				}
				append(&spans, ..span)
			}
			testing.expectf(t, bytes.equal(spans[:], ref[:][start:end]), "span iteration at step %v", step)
			delete(spans)
		}

		if step % 50 == 0 {
			// Snapshot persistence probe.
			root_before := tree.root
			content := bytes.clone(ref[:], context.allocator)
			next_op := "extra-😀\r\n"
			probe_pos := int(next(&state) % u64(len(ref) + 1))
			testing.expect(t, errs.ok(rope.tree_insert(&tree, probe_pos, bytes_of(next_op))))
			ok, _ := inject_at_elems(&ref, probe_pos, ..bytes_of(next_op))
			testing.expect(t, ok)
			rev += 1
			old, rerr := rope.tree_read_root_all(&tree, root_before, rope.Byte_Range{0, len(content)})
			testing.expect(t, errs.ok(rerr))
			testing.expectf(t, bytes.equal(old, content), fmt.tprintf("snapshot probe at step %v", step))
			delete(old)
			delete(content, context.allocator)
		}
	}
}
