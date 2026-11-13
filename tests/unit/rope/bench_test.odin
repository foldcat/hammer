// Benchmarks and boundedness tests for the rope tree (M02.08):
// `hammer:core/rope` — the SPECS.md §7.6 complexity targets as
// executable checks plus wall-clock measurements.
//
// Deterministic structural guards run with the ordinary test suite
// and are the primary protection: a small edit on a large buffer must
// not allocate anywhere near the buffer's size through the caller
// allocator, must not create a node count anywhere near the tree's
// existing node count, and must keep the tree height far below any
// linear-depth shape. Those three deltas together catch whole-buffer
// copies and flatten-rebuild regressions deterministically (a
// flattening insert would either copy the buffer through the caller
// allocator, rebuild the whole leaf population, or both).
//
// Wall-clock comparisons (insert scaling and small-range reads) use
// generous ratios (50x) so they stay meaningful without being flaky
// under the default multi-threaded test runner; run them with
// `-define:ODIN_TEST_BENCHMARKS=true` (see make.odin `bench`) to also
// print the measured times.
package rope_test

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import rope "hammer:core/rope"

// ODIN_TEST_BENCHMARKS toggles the wall-clock measurements in the
// benchmark tests (make.odin passes it for the `bench` target).
BENCHMARKS :: #config(ODIN_TEST_BENCHMARKS, false)

// Counting_Allocator wraps a backing allocator (the test runner's
// context allocator) and records how many bytes were allocated through
// it. `total` is cumulative across the measured operation — an upper
// bound on the operation's peak, which is what the no-whole-buffer-
// copy check needs: a flattening edit would allocate the whole buffer
// through this allocator.
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

// test_tree_small_edit_bounded pins the no-whole-buffer-copy invariant
// deterministically (SPECS.md §7.6): a small insert and a small delete
// on a 2 MiB tree allocate a tiny fraction of the buffer through the
// caller allocator, create a bounded number of new tree nodes, and
// keep the height far below the buffer's chunk count.
@(test)
test_tree_small_edit_bounded :: proc(t: ^testing.T) {
	BUFFER_SIZE :: 2 * 1024 * 1024
	ALLOC_BOUND :: 256 * 1024 // measured scratch must stay well under this

	store: chunk.Store
	chunk.init(&store, {chunk_size = 4096})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree)

	// Build 2 MiB of distinct-enough content (repeating 256-byte
	// pattern; interning dedups, the tree holds ~512 chunks).
	pattern: [256]u8
	for i in 0 ..< len(pattern) {
		pattern[i] = u8(i)
	}
	big := make([]u8, BUFFER_SIZE, context.allocator)
	defer delete(big, context.allocator)
	for i in 0 ..< len(big) {
		big[i] = pattern[i % len(pattern)]
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree, big)))

	// The shape is a B-tree, not a list: far below the linear bound.
	height := rope.tree_height(&tree)
	testing.expectf(t, height >= 2 && height < 64, "tree height %v must be logarithmic", height)

	// The measured allocator counts every byte the edit allocates
	// through the caller allocator (the tree node pool is self-owned,
	// which is why the node-count delta is checked separately).
	counter: Counting_Allocator
	counting_allocator_init(&counter, context.allocator)
	measured := counting_allocator(&counter)

	nodes_before := rope.tree_node_count(&tree)
	chunks_before := chunk.chunk_count(&store)
	bytes_before := chunk.total_bytes(&store)

	// Small insert in the middle: 32 bytes that are not interned yet.
	insert_data: [32]u8
	for i in 0 ..< 32 {
		insert_data[i] = 0xE0 + u8(i) // stray-continuation range, distinct from the pattern
	}
	insert_err := rope.tree_insert(&tree, BUFFER_SIZE / 2, insert_data[:], measured)
	testing.expect(t, errs.ok(insert_err), "insert must succeed")
	expect_tree_ok(t, &tree, "after bounded small insert")
	testing.expectf(
		t,
		counter.total <= ALLOC_BOUND,
		"small insert allocated %v bytes through the caller allocator (bound %v); a whole-buffer copy would exceed it",
		counter.total,
		ALLOC_BOUND,
	)
	testing.expectf(
		t,
		rope.tree_node_count(&tree)-nodes_before < 64,
		"small insert created %v nodes; a rebuild would create hundreds",
		rope.tree_node_count(&tree)-nodes_before,
	)
	testing.expectf(
		t,
		chunk.total_bytes(&store)-bytes_before <= chunk.chunk_size(&store)+32,
		"small insert interned %v new store bytes; only the inserted bytes may be interned",
		chunk.total_bytes(&store)-bytes_before,
	)
	testing.expectf(
		t,
		chunk.chunk_count(&store)-chunks_before <= 1,
		"small insert interned %v new chunks",
		chunk.chunk_count(&store)-chunks_before,
	)
	testing.expectf(
		t,
		rope.tree_height(&tree) < 64,
		"tree height %v after the insert must stay logarithmic",
		rope.tree_height(&tree),
	)
	// The insert actually landed.
	got := make([]byte, 32, context.allocator)
	defer delete(got, context.allocator)
	n, rerr := rope.tree_read(&tree, rope.Byte_Range{BUFFER_SIZE / 2, BUFFER_SIZE / 2 + 32}, got, measured)
	testing.expect(t, errs.ok(rerr) && n == 32)
	testing.expect(t, bytes.equal(got, insert_data[:]), "inserted content must read back")

	// Small delete (48 bytes) with the same bounds.
	counter.total = 0
	nodes_before = rope.tree_node_count(&tree)
	del_err := rope.tree_delete(&tree, rope.Byte_Range{BUFFER_SIZE / 3, BUFFER_SIZE / 3 + 48}, measured)
	testing.expect(t, errs.ok(del_err), "delete must succeed")
	expect_tree_ok(t, &tree, "after bounded small delete")
	testing.expectf(
		t,
		counter.total <= ALLOC_BOUND,
		"small delete allocated %v bytes through the caller allocator (bound %v)",
		counter.total,
		ALLOC_BOUND,
	)
	testing.expectf(
		t,
		rope.tree_node_count(&tree)-nodes_before < 64,
		"small delete created %v nodes",
		rope.tree_node_count(&tree)-nodes_before,
	)
	testing.expectf(t, rope.tree_height(&tree) < 64, "height %v after the delete", rope.tree_height(&tree))
}

// test_tree_huge_single_line pins the huge-individual-line property
// (SPECS.md §7.7): a 4 MiB single line keeps its metrics and line
// lookups consistent without any per-line storage.
@(test)
test_tree_huge_single_line :: proc(t: ^testing.T) {
	LINE_SIZE :: 4 * 1024 * 1024

	store: chunk.Store
	chunk.init(&store, {chunk_size = 4096})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree)

	line := make([]byte, LINE_SIZE, context.allocator)
	defer delete(line, context.allocator)
	for i in 0 ..< len(line) {
		line[i] = u8('a' + (i % 26))
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree, line)))

	testing.expect(t, rope.tree_byte_count(&tree) == LINE_SIZE)
	testing.expect(t, rope.tree_scalar_count(&tree) == LINE_SIZE)
	testing.expect(t, rope.tree_line_count(&tree) == 1, "a break-free buffer is one line")
	testing.expect(t, rope.tree_height(&tree) < 64)

	start, serr := rope.tree_line_start(&tree, 0)
	testing.expect(t, errs.ok(serr) && start == 0)
	end_pos, eerr := rope.tree_line_end(&tree, 0)
	testing.expect(t, errs.ok(eerr) && end_pos == LINE_SIZE)

	// Sampled line/column round-trips along the whole line.
	sample_step := LINE_SIZE / 128
	for b := 0; b <= LINE_SIZE; b += sample_step {
		l, lerr := rope.tree_byte_to_line(&tree, b)
		testing.expect(t, errs.ok(lerr) && l == 0, "every byte of a single line is line 0")
		l2, col, cerr := rope.tree_byte_to_line_col(&tree, b)
		testing.expect(t, errs.ok(cerr) && l2 == 0 && int(col) == b, "column must equal the byte offset on ASCII")
		back, berr := rope.tree_line_col_to_byte(&tree, 0, col)
		testing.expect(t, errs.ok(berr) && back == b, "line_col_to_byte must round-trip")
	}
	expect_tree_ok(t, &tree, "after huge single line")
}

// test_bench_insert_scaling compares the per-op cost of a small insert
// on a small tree and a 4 MiB tree: with a logarithmic insert the ratio
// must stay far below the 50x guard (a flattening implementation would
// scale with the buffer, ~1000x here).
@(test)
test_bench_insert_scaling :: proc(t: ^testing.T) {
	LARGE_SIZE :: 4 * 1024 * 1024
	SMALL_SIZE :: 16 * 1024

	store_small: chunk.Store
	chunk.init(&store_small, {chunk_size = 4096})
	defer chunk.destroy(&store_small)
	store_large: chunk.Store
	chunk.init(&store_large, {chunk_size = 4096})
	defer chunk.destroy(&store_large)

	tree_small: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree_small, &store_small, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree_small)
	tree_large: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree_large, &store_large, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree_large)

	small := make([]byte, SMALL_SIZE, context.allocator)
	defer delete(small, context.allocator)
	for i in 0 ..< len(small) {
		small[i] = u8('a' + (i % 26))
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree_small, small)))

	large := make([]byte, LARGE_SIZE, context.allocator)
	defer delete(large, context.allocator)
	for i in 0 ..< len(large) {
		large[i] = u8('a' + (i % 26))
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree_large, large)))

	insert_per_op :: proc(t: ^testing.T, tree: ^rope.Tree, rounds: int) -> i64 {
		data: [8]u8
		for i in 0 ..< 8 {
			data[i] = 0xC8 + u8(i) // uninterned multi-byte leads
		}
		start := time.tick_now()
		pos := rope.tree_byte_count(tree) / 2
		for r in 0 ..< rounds {
			_ = r
			err := rope.tree_insert(tree, pos, data[:])
			testing.expect(t, errs.ok(err), "bench insert must succeed")
		}
		elapsed := time.tick_diff(start, time.tick_now())
		return time.duration_nanoseconds(elapsed) / i64(rounds)
	}

	small_per_op := insert_per_op(t, &tree_small, 400)
	large_per_op := insert_per_op(t, &tree_large, 400)

	if BENCHMARKS {
		fmt.printf("[bench] tree small insert: %v ns/op\n", small_per_op)
		fmt.printf("[bench] tree 4 MiB insert: %v ns/op\n", large_per_op)
		fmt.printf("[bench] tree insert large/small ratio: %.2f\n", f64(large_per_op)/f64(small_per_op))
	}
	// Generous: a flattening rebuild scales with buffer size (256x here
	// before cache effects) — 50x keeps a wide margin while still
	// catching it; the absolute escape (100 µs) absorbs load noise.
	testing.expectf(
		t,
		large_per_op <= 50*small_per_op || large_per_op < 100_000,
		"small insert on the 4 MiB tree took %v ns/op vs %v ns/op on the 16 KiB tree (50x guard)",
		large_per_op,
		small_per_op,
	)
	expect_tree_ok(t, &tree_large, "after insert benchmark")
}

// test_bench_range_read compares the cost of reading a small range on
// a 4 MiB tree against reading the same range on a small tree: the
// visible-range read must be proportional to the range, not the
// buffer.
@(test)
test_bench_range_read :: proc(t: ^testing.T) {
	LARGE_SIZE :: 4 * 1024 * 1024
	SMALL_SIZE :: 16 * 1024

	store_small: chunk.Store
	chunk.init(&store_small, {chunk_size = 4096})
	defer chunk.destroy(&store_small)
	store_large: chunk.Store
	chunk.init(&store_large, {chunk_size = 4096})
	defer chunk.destroy(&store_large)

	tree_small: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree_small, &store_small, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree_small)
	tree_large: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree_large, &store_large, {target_leaf_bytes = 4096})))
	defer rope.tree_destroy(&tree_large)

	small := make([]byte, SMALL_SIZE, context.allocator)
	defer delete(small, context.allocator)
	for i in 0 ..< len(small) {
		small[i] = u8('a' + (i % 26))
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree_small, small)))

	large := make([]byte, LARGE_SIZE, context.allocator)
	defer delete(large, context.allocator)
	for i in 0 ..< len(large) {
		large[i] = u8('a' + (i % 26))
	}
	testing.expect(t, errs.ok(rope.tree_append(&tree_large, large)))

	read_per_op :: proc(t: ^testing.T, tree: ^rope.Tree, rounds: int) -> i64 {
		out: [64]u8
		start := time.tick_now()
		for r in 0 ..< rounds {
			pos := (r * 977) % (rope.tree_byte_count(tree) - 64)
			n, err := rope.tree_read(tree, rope.Byte_Range{pos, pos + 64}, out[:])
			testing.expect(t, errs.ok(err) && n == 64, "bench read must succeed")
		}
		elapsed := time.tick_diff(start, time.tick_now())
		return time.duration_nanoseconds(elapsed) / i64(rounds)
	}

	small_per_op := read_per_op(t, &tree_small, 400)
	large_per_op := read_per_op(t, &tree_large, 400)

	if BENCHMARKS {
		fmt.printf("[bench] tree small range read: %v ns/op\n", small_per_op)
		fmt.printf("[bench] tree 4 MiB range read: %v ns/op\n", large_per_op)
		fmt.printf("[bench] tree range-read large/small ratio: %.2f\n", f64(large_per_op)/f64(small_per_op))
	}
	testing.expectf(
		t,
		large_per_op <= 50*small_per_op || large_per_op < 100_000,
		"64-byte range read on the 4 MiB tree took %v ns/op vs %v ns/op on the 16 KiB tree (50x guard)",
		large_per_op,
		small_per_op,
	)
}
