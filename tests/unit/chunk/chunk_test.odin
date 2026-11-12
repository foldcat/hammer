// Tests for the immutable backing chunk store (M02.01):
// `hammer:core/chunk` — splitting, content interning, id-list
// round-trips, view stability, the degenerate-hash collision path,
// allocation-failure behavior, and arena lifetime.
package chunk_test

import "core:bytes"
import "core:fmt"
import "core:strings"
import "core:testing"
import mem_virtual "core:mem/virtual"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"

// insert_text stores `text` and expects success; the returned id list
// is owned by the caller.
insert_text :: proc(t: ^testing.T, s: ^chunk.Store, text: string) -> [dynamic]chunk.Chunk_ID {
	ids, err := chunk.insert(s, transmute([]byte)text)
	if !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		defer delete(desc, context.allocator)
		errs.destroy(&err)
		testing.expectf(t, false, "insert(%q) failed: %s", text, desc)
		return {}
	}
	return ids
}

// concat_ids returns the concatenation of the chunks behind `ids`.
concat_ids :: proc(s: ^chunk.Store, ids: [dynamic]chunk.Chunk_ID) -> [dynamic]u8 {
	out := make([dynamic]u8, context.allocator)
	for id in ids {
		append(&out, ..chunk.data(s, id))
	}
	return out
}

// ref_find linear-scans the reference chunk list; returns the 1-based
// id of a byte-equal chunk, or 0 when absent. The trivial model the
// hash-based intern table is differentially tested against.
ref_find :: proc(chunks: [dynamic][]u8, data: []u8) -> int {
	for c, i in chunks {
		if bytes.equal(c, data) {
			return i + 1
		}
	}
	return 0
}

// test_split_and_roundtrip pins the splitting contract: input is split
// into chunk_size pieces (last may be shorter), the returned ids
// reproduce the input byte-for-byte, and the bookkeeping fields agree.
@(test)
test_split_and_roundtrip :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 4})
	defer chunk.destroy(&s)

	ids := insert_text(t, &s, "abcdefghij")
	defer delete(ids)
	testing.expect(t, len(ids) == 3)
	testing.expect(t, len(chunk.data(&s, ids[0])) == 4)
	testing.expect(t, len(chunk.data(&s, ids[1])) == 4)
	testing.expect(t, len(chunk.data(&s, ids[2])) == 2)
	testing.expect(t, chunk.chunk_count(&s) == 3)
	testing.expect(t, chunk.total_bytes(&s) == 10)
	testing.expect(t, chunk.chunk_size(&s) == 4)

	got := concat_ids(&s, ids)
	defer delete(got)
	testing.expect(t, bytes.equal(got[:], transmute([]byte)string("abcdefghij")))

	// An exact multiple of the chunk size yields full chunks only.
	ids2 := insert_text(t, &s, "abcdefgh")
	defer delete(ids2)
	testing.expect(t, len(ids2) == 2)
	testing.expect(t, len(chunk.data(&s, ids2[0])) == 4)
	testing.expect(t, len(chunk.data(&s, ids2[1])) == 4)
}

// test_interning_dedup pins hash-consing: byte-identical inserts share
// ids and storage.
@(test)
test_interning_dedup :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 64})
	defer chunk.destroy(&s)

	ids_a := insert_text(t, &s, "hello world")
	defer delete(ids_a)
	ids_b := insert_text(t, &s, "hello world")
	defer delete(ids_b)

	testing.expect(t, len(ids_a) == 1 && len(ids_b) == 1)
	testing.expect(t, ids_a[0] == ids_b[0])
	testing.expect(t, chunk.chunk_count(&s) == 1)
	testing.expect(t, chunk.total_bytes(&s) == 11)
}

// test_dedup_across_splits checks that interning applies to each split
// chunk independently — including across different inserts and inside
// one insert.
@(test)
test_dedup_across_splits :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 4})
	defer chunk.destroy(&s)

	ids_a := insert_text(t, &s, "abcdef") // "abcd", "ef"
	defer delete(ids_a)
	testing.expect(t, len(ids_a) == 2 && ids_a[0] != ids_a[1])

	ids_b := insert_text(t, &s, "abcd") // reuses ids_a[0]
	defer delete(ids_b)
	testing.expect(t, len(ids_b) == 1 && ids_b[0] == ids_a[0])

	ids_c := insert_text(t, &s, "ef") // reuses ids_a[1]
	defer delete(ids_c)
	testing.expect(t, len(ids_c) == 1 && ids_c[0] == ids_a[1])

	// One insert can return the same id twice: "abab" is interned once
	// and referenced by both split pieces.
	ids_d := insert_text(t, &s, "abababab")
	defer delete(ids_d)
	testing.expect(t, len(ids_d) == 2 && ids_d[0] == ids_d[1])

	ids_e := insert_text(t, &s, "abcdef") // both reuse
	defer delete(ids_e)
	testing.expect(t, ids_e[0] == ids_a[0] && ids_e[1] == ids_a[1])

	testing.expect(t, chunk.chunk_count(&s) == 3)
	testing.expect(t, chunk.total_bytes(&s) == 10) // "abcd"+"ef"+"abab"
}

// test_empty_and_nil pins the edge contracts: empty input stores
// nothing and returns an empty list; the nil id reads as empty.
@(test)
test_empty_and_nil :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 4})
	defer chunk.destroy(&s)

	ids, err := chunk.insert(&s, {})
	testing.expect(t, errs.ok(err))
	testing.expect(t, len(ids) == 0)
	delete(ids)

	testing.expect(t, chunk.chunk_count(&s) == 0)
	testing.expect(t, chunk.total_bytes(&s) == 0)
	testing.expect(t, len(chunk.data(&s, 0)) == 0)
}

// test_views_stable pins the immutability contract: a view taken before
// further inserts (including intern-table growth) stays byte-identical.
@(test)
test_views_stable :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 8})
	defer chunk.destroy(&s)

	ids := insert_text(t, &s, "alpha")
	defer delete(ids)
	view := chunk.data(&s, ids[0])
	testing.expect(t, transmute(string)view == "alpha")

	// Force real growth of both the chunk index and the intern table
	// with many distinct chunks.
	for i in 0 ..< 40 {
		text := fmt.aprintf("payload-%02d", i, allocator = context.allocator)
		ids_i := insert_text(t, &s, text)
		delete(ids_i)
		delete(text, context.allocator)
	}

	testing.expect(t, transmute(string)view == "alpha", "published bytes must never change")
	testing.expect(t, bytes.equal(view, chunk.data(&s, ids[0])))
}

// const_hash degenerates every content to one hash value, forcing the
// intern table down its collision/probing path.
const_hash :: proc(data: []byte) -> u64 {
	return 1
}

// test_collision_path runs the store with a constant hash: every
// insert collides, so lookup and dedup must work by byte comparison
// alone, and all content must round-trip. The chunk size exceeds every
// content so each insert is exactly one chunk.
@(test)
test_collision_path :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 64, hash = const_hash})
	defer chunk.destroy(&s)

	contents := []string{"a", "b", "abc", "ab", "ba", "hello", "world", "hello world", "abcde", "abcdef"}
	first_ids: [dynamic]chunk.Chunk_ID
	defer delete(first_ids)

	for text in contents {
		ids := insert_text(t, &s, text)
		got := concat_ids(&s, ids)
		testing.expectf(t, bytes.equal(got[:], transmute([]byte)text), "round-trip failed for %q", text)
		delete(got)
		append(&first_ids, ids[0])
		delete(ids)
	}

	// Second pass: every content must dedup onto the first pass ids.
	for text, i in contents {
		ids := insert_text(t, &s, text)
		testing.expectf(t, ids[0] == first_ids[i], "dedup failed under collision for %q", text)
		delete(ids)
	}

	testing.expect(t, chunk.chunk_count(&s) == len(contents))
	total := 0
	for text in contents {
		total += len(text)
	}
	testing.expect(t, chunk.total_bytes(&s) == total)
}

// test_allocation_failure injects a fixed-size arena and fills it: the
// store must fail with .Resource_Limit (never panic or corrupt) and
// remain consistent and readable afterwards.
@(test)
test_allocation_failure :: proc(t: ^testing.T) {
	buf := make([]byte, 4 * 1024)
	defer delete(buf)
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_buffer(&arena, buf) == nil)
	defer mem_virtual.arena_destroy(&arena)
	alloc := mem_virtual.arena_allocator(&arena)

	s: chunk.Store
	chunk.init(&s, {chunk_size = 1024}, alloc)
	defer chunk.destroy(&s)

	filler := make([]byte, 1024)
	defer delete(filler)

	failed := false
	for i in 0 ..< 64 {
		filler[0] = u8(i) // distinct content per insert (else it dedups)
		ids, ierr := chunk.insert(&s, filler, context.allocator)
		if errs.ok(ierr) {
			delete(ids)
			continue
		}
		testing.expect(t, ierr.kind == .Resource_Limit, "allocation failure must surface as .Resource_Limit")
		desc := errs.describe(ierr, context.allocator)
		testing.expect(
			t,
			strings.contains(desc, "resource limit"),
			"error description must name the kind",
		)
		delete(desc, context.allocator)
		errs.destroy(&ierr)
		failed = true
		break
	}
	testing.expect(t, failed, "the fixed buffer arena must eventually exhaust")

	// The store stays consistent: bookkeeping agrees and earlier chunks
	// keep their content.
	testing.expect(t, chunk.chunk_count(&s) > 0)
	testing.expect(t, chunk.total_bytes(&s) == chunk.chunk_count(&s) * 1024)
	testing.expect(t, len(chunk.data(&s, 1)) == 1024)
}

// test_arena_growing_end_to_end mirrors the product shape (main's perm
// arena): all store allocation comes from one growing arena and a
// single free_all reclaims it after destroy.
@(test)
test_arena_growing_end_to_end :: proc(t: ^testing.T) {
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_growing(&arena) == nil)
	defer mem_virtual.arena_destroy(&arena)
	defer mem_virtual.arena_free_all(&arena)
	alloc := mem_virtual.arena_allocator(&arena)

	s: chunk.Store
	chunk.init(&s, {chunk_size = 256}, alloc)
	defer chunk.destroy(&s)

	ids := insert_text(t, &s, "the quick brown fox jumps over the lazy dog")
	delete(ids)
	ids = insert_text(t, &s, "the quick brown fox jumps over the lazy dog") // dedup
	delete(ids)
	testing.expect(t, chunk.chunk_count(&s) == 1)

	chunk.destroy(&s)
	mem_virtual.arena_free_all(&arena)
	testing.expect(t, arena.total_used == 0, "free_all must reclaim the store's memory")
}

// test_randomized_roundtrip is a deterministic differential property:
// 300 seeded inserts of varied lengths are checked against a trivial
// reference model (linear-scan interning), so the real hash table —
// probing, growth, and byte-compare collision resolution — is
// exercised against an independent implementation.
@(test)
test_randomized_roundtrip :: proc(t: ^testing.T) {
	s: chunk.Store
	chunk.init(&s, {chunk_size = 7})
	defer chunk.destroy(&s)

	alphabet := transmute([]byte)string("abcdefghijklmnopqrstuvwxyz0123456789\n\t")

	// Reference model: the chunk stream the store should publish, with
	// linear-scan interning instead of hashing.
	ref_chunks := make([dynamic][]u8, context.allocator)
	defer {
		for c in ref_chunks {
			delete(c, context.allocator)
		}
		delete(ref_chunks)
	}

	// xorshift64 — deterministic across platforms and runs.
	state: u64 = 0x9e37_79b9_7f4a_7c15
	next := proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}

	for step in 0 ..< 300 {
		piece := make([]u8, int(next(&state) % 60), context.allocator)
		for &b in piece {
			b = alphabet[int(next(&state) % u64(len(alphabet)))]
		}

		ids, err := chunk.insert(&s, piece, context.allocator)
		testing.expect(t, errs.ok(err), "insert must not fail with a healthy allocator")

		// The id list must reproduce the piece byte-for-byte.
		got := concat_ids(&s, ids)
		testing.expectf(t, bytes.equal(got[:], piece), "id list round-trip failed at step %v", step)
		delete(got)

		// Every id must match the reference model exactly.
		cs := chunk.chunk_size(&s)
		k := (len(piece) - 1) / cs + 1 if len(piece) > 0 else 0
		testing.expect(t, len(ids) == k)
		for i in 0 ..< k {
			sub := piece[i * cs:min((i + 1) * cs, len(piece))]
			ref_id := ref_find(ref_chunks, sub)
			if ref_id == 0 {
				append(&ref_chunks, bytes.clone(sub, context.allocator))
				ref_id = len(ref_chunks)
			}
			testing.expectf(t, ids[i] == chunk.Chunk_ID(ref_id), "id mismatch at step %v chunk %v", step, i)
		}
		delete(ids)
		delete(piece, context.allocator)
	}

	// The store's published chunk stream must match the reference
	// chunk-for-chunk.
	testing.expect(t, chunk.chunk_count(&s) == len(ref_chunks))
	total := 0
	for c, i in ref_chunks {
		total += len(c)
		testing.expect(t, bytes.equal(chunk.data(&s, chunk.Chunk_ID(i + 1)), c))
	}
	testing.expect(t, chunk.total_bytes(&s) == total)
}
