// Benchmarks and boundedness tests for the transaction layer (M02.08):
// `hammer:core/txn` — small edits applied to large documents must not
// allocate anywhere near the document size through the caller
// allocator and must not rebuild the tree node population (SPECS.md
// §7.6: no whole-buffer copies for small edits; no flattening).
//
// The deterministic structural guards (caller-allocator bytes, node
// count deltas, tree height, chunk-store growth) run with the ordinary
// test suite. Wall-clock comparisons run with generous 50x ratios and
// print their measurements under `-define:ODIN_TEST_BENCHMARKS=true`
// (make.odin `bench`).
package txn_test

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

BENCHMARKS :: #config(ODIN_TEST_BENCHMARKS, false)

// Counting_Allocator wraps a backing allocator (the test runner's
// context allocator) and records how many bytes were allocated through
// it. `total` is cumulative across the measured operation; it is an
// upper bound on the operation's peak, which is exactly what the
// no-whole-buffer-copy check needs: a flattening edit would allocate
// the whole document through this allocator.
Counting_Allocator :: struct {
	backing: mem.Allocator,
	total:   int,
}

counting_allocator_init :: proc(c: ^Counting_Allocator, backing: mem.Allocator) {
	c.backing = backing
	c.total = 0
}

counting_allocator :: proc(c: ^Counting_Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = counting_allocator_proc, data = c}
}

counting_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size: int,
	alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	result: []byte,
	err: mem.Allocator_Error,
) {
	c := (^Counting_Allocator)(allocator_data)
	result, err = c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
	if err == .None {
		switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			c.total += size
		case .Free_All:
			c.total = 0
		case .Free, .Resize, .Resize_Non_Zeroed, .Query_Features, .Query_Info:
		}
	}
	return
}

// test_doc_small_edit_bounded pins the transaction-level
// no-whole-buffer-copy invariant: a small insert and a small delete on
// a 2 MiB document allocate a tiny fraction of the document through
// the apply allocator, create a bounded number of tree nodes, and
// leave the tree logarithmic.
@(test)
test_doc_small_edit_bounded :: proc(t: ^testing.T) {
	DOC_SIZE :: 2 * 1024 * 1024
	ALLOC_BOUND :: 256 * 1024

	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4096, target_leaf_bytes = 4096})))
	defer txn.doc_destroy(&doc)

	// Build the large document in one transaction (a repeating
	// pattern; the store interns it into ~512 chunks).
	pattern: [256]u8
	for i in 0 ..< len(pattern) {
		pattern[i] = u8(i)
	}
	big := make([]byte, DOC_SIZE, context.allocator)
	defer delete(big, context.allocator)
	for i in 0 ..< len(big) {
		big[i] = pattern[i % len(pattern)]
	}
	seed_tr: txn.Transaction
	seed_tr = {source = .Edit, base_revision = 0, ops = {txn.Operation(txn.Insert{pos = 0, data = big})}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &seed_tr)))

	expect_doc_ok(t, &doc, "large document")
	testing.expectf(
		t,
		rope.tree_height(&doc.tree) >= 2 && rope.tree_height(&doc.tree) < 64,
		"tree height %v must be logarithmic",
		rope.tree_height(&doc.tree),
	)

	// The measured allocator counts every byte the apply allocates
	// through the caller allocator (the tree pool is self-owned, which
	// is why the node-count delta is checked separately).
	counter: Counting_Allocator
	counting_allocator_init(&counter, context.allocator)
	measured := counting_allocator(&counter)

	nodes_before := rope.tree_node_count(&doc.tree)
	chunks_before := chunk.chunk_count(&doc.store)
	bytes_before := chunk.total_bytes(&doc.store)
	rev_before := txn.doc_revision(&doc)

	// Small insert in the middle: 32 bytes that are not interned yet.
	insert_data: [32]u8
	for i in 0 ..< 32 {
		insert_data[i] = 0xE0 + u8(i)
	}
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = rev_before, ops = {txn.Operation(txn.Insert{pos = DOC_SIZE / 2, data = insert_data[:]})}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr, measured)), "small apply must succeed")
	expect_doc_ok(t, &doc, "after bounded small apply")
	testing.expectf(
		t,
		counter.total <= ALLOC_BOUND,
		"small apply allocated %v bytes through the caller allocator (bound %v); a whole-buffer copy would exceed it",
		counter.total,
		ALLOC_BOUND,
	)
	testing.expectf(
		t,
		rope.tree_node_count(&doc.tree)-nodes_before < 64,
		"small apply created %v tree nodes; a rebuild would create hundreds",
		rope.tree_node_count(&doc.tree)-nodes_before,
	)
	testing.expectf(
		t,
		chunk.total_bytes(&doc.store)-bytes_before <= chunk.chunk_size(&doc.store)+32,
		"small apply interned %v new store bytes; only the inserted bytes may be interned",
		chunk.total_bytes(&doc.store)-bytes_before,
	)
	testing.expectf(t, chunk.chunk_count(&doc.store)-chunks_before <= 1, "small apply interned new chunks")
	testing.expectf(t, rope.tree_height(&doc.tree) < 64, "height %v after the apply", rope.tree_height(&doc.tree))

	// The insert landed in the document.
	got := make([]byte, 32, context.allocator)
	defer delete(got, context.allocator)
	n, rerr := rope.tree_read(&doc.tree, rope.Byte_Range{DOC_SIZE / 2, DOC_SIZE / 2 + 32}, got, measured)
	testing.expect(t, errs.ok(rerr) && n == 32)
	testing.expect(t, bytes.equal(got, insert_data[:]), "inserted content must read back")

	// Small delete (48 bytes) with the same bounds.
	counter.total = 0
	nodes_before = rope.tree_node_count(&doc.tree)
	tr = {source = .Cut, base_revision = txn.doc_revision(&doc), ops = {delete_op(DOC_SIZE / 3, DOC_SIZE / 3 + 48)}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr, measured)), "small delete must succeed")
	expect_doc_ok(t, &doc, "after bounded small delete")
	testing.expectf(t, counter.total <= ALLOC_BOUND, "small delete allocated %v bytes (bound %v)", counter.total, ALLOC_BOUND)
	testing.expectf(t, rope.tree_node_count(&doc.tree)-nodes_before < 64, "small delete created nodes")
	testing.expectf(t, rope.tree_height(&doc.tree) < 64, "height %v after the delete", rope.tree_height(&doc.tree))
}

// test_bench_doc_apply_scaling compares the per-op cost of small
// transactions on a small document and a 4 MiB document: transaction
// application must stay logarithmic in the document size.
@(test)
test_bench_doc_apply_scaling :: proc(t: ^testing.T) {
	LARGE_SIZE :: 4 * 1024 * 1024
	SMALL_SIZE :: 32 * 1024

	doc_small: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc_small, {chunk_size = 4096})))
	defer txn.doc_destroy(&doc_small)
	doc_large: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc_large, {chunk_size = 4096})))
	defer txn.doc_destroy(&doc_large)

	small := make([]byte, SMALL_SIZE, context.allocator)
	defer delete(small, context.allocator)
	for i in 0 ..< len(small) {
		small[i] = u8('a' + (i % 26))
	}
	seed_small: txn.Transaction
	seed_small = {source = .Edit, base_revision = 0, ops = {txn.Operation(txn.Insert{pos = 0, data = small})}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc_small, &seed_small)))

	large := make([]byte, LARGE_SIZE, context.allocator)
	defer delete(large, context.allocator)
	for i in 0 ..< len(large) {
		large[i] = u8('a' + (i % 26))
	}
	seed_large: txn.Transaction
	seed_large = {source = .Edit, base_revision = 0, ops = {txn.Operation(txn.Insert{pos = 0, data = large})}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc_large, &seed_large)))

	apply_per_op :: proc(t: ^testing.T, doc: ^txn.Doc, rounds: int) -> i64 {
		data: [8]u8
		for i in 0 ..< 8 {
			data[i] = 0xC8 + u8(i)
		}
		start := time.tick_now()
		for r in 0 ..< rounds {
			_ = r
			tr: txn.Transaction
			tr = {
				source = .Typing,
				base_revision = txn.doc_revision(doc),
				ops = {txn.Operation(txn.Insert{pos = rope.tree_byte_count(&doc.tree) / 2, data = data[:]})},
			}
			testing.expect(t, errs.ok(txn.doc_apply(doc, &tr)), "bench apply must succeed")
		}
		elapsed := time.tick_diff(start, time.tick_now())
		return time.duration_nanoseconds(elapsed) / i64(rounds)
	}

	small_per_op := apply_per_op(t, &doc_small, 200)
	large_per_op := apply_per_op(t, &doc_large, 200)

	if BENCHMARKS {
		fmt.printf("[bench] doc small apply: %v ns/op\n", small_per_op)
		fmt.printf("[bench] doc 4 MiB apply: %v ns/op\n", large_per_op)
		fmt.printf("[bench] doc apply large/small ratio: %.2f\n", f64(large_per_op)/f64(small_per_op))
	}
	testing.expectf(
		t,
		large_per_op <= 50*small_per_op || large_per_op < 100_000,
		"small apply on the 4 MiB doc took %v ns/op vs %v ns/op on the 32 KiB doc (50x guard)",
		large_per_op,
		small_per_op,
	)
	expect_doc_ok(t, &doc_large, "after apply benchmark")
}
