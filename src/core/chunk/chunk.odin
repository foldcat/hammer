// Package chunk: immutable backing chunks for the text engine (M02.01).
//
// The first layer of the persistent piece-rope (SPECS.md §7.1): a
// `Store` owns immutable, content-interned byte chunks. The rope layers
// (M02.02 leaves/metrics, M02.03 persistent roots) reference chunks by
// stable `Chunk_ID` values through pieces; this package knows nothing
// about pieces, leaves, or coordinates.
//
// Contracts:
//
// - **Immutable.** Chunk content is fixed the moment it is published by
//   `insert`. `data` returns a borrowed view; the view stays valid and
//   byte-identical for the whole store lifetime, across any number of
//   later inserts. Neither this package nor any caller may mutate
//   returned bytes.
// - **Interned.** `insert` splits its input into `chunk_size`-byte
//   chunks and interns each chunk by content: byte-identical chunks get
//   the same `Chunk_ID` and share one allocation (hash-consing). An
//   insert of already-stored content allocates no chunk storage.
// - **Single owner.** A `Store` lives at a fixed location and is passed
//   by pointer. It is not thread-safe and expects one mutator thread
//   (AGENTS.md §13). Because chunks are immutable, borrowed views may
//   be read on other threads while the owning thread does not call
//   `destroy`; coordinating that lifetime is the caller's contract.
// - **Ownership.** The store uses the allocator passed to `init` for
//   everything it keeps: chunk data, the chunk index, and the intern
//   table. `destroy` releases them with individual frees (with an arena
//   allocator those frees are no-ops and `free_all` reclaims the memory
//   — AGENTS.md §10.5). `insert` additionally allocates the returned id
//   list with its explicit `allocator` argument; the caller owns that
//   list and deletes it.
// - **Failure.** Allocation failures surface as `.Resource_Limit`
//   errors and leave the store consistent. Chunks interned before a
//   failed insert remain interned — a retry deduplicates onto them.
//   Error messages are allocated with the caller's `insert` allocator,
//   never the store's, so they cannot fail together with the store.
//
// Backend-free: imports only `core:` packages and `core/errs`, so it
// builds headless without the Sokol collection (SPECS.md §4.2).
package chunk

import "base:runtime"
import "core:bytes"
import "core:hash/xxhash"
import "core:mem"

import errs "../errs"

// Chunk_ID identifies an immutable chunk inside a Store. Values are
// only meaningful within the store that produced them. The nil id (0)
// is the empty chunk: `data` returns an empty slice, and `insert` never
// returns it.
Chunk_ID :: distinct u64

// Hash_Proc hashes chunk content for the intern table. It must be
// deterministic. The result feeds the intern table; any 64-bit value
// is acceptable because collisions are resolved by byte comparison.
Hash_Proc :: #type proc(data: []byte) -> u64

// DEFAULT_CHUNK_SIZE is the recommended chunk size (4 KiB): small
// enough that pieces stay granular, large enough that per-chunk
// overhead stays negligible. Callers pass it explicitly in Options.
DEFAULT_CHUNK_SIZE :: 4 * 1024

// default_hash is the intern hash used when Options.hash is nil:
// XXH64, wrapped so its single-argument shape matches Hash_Proc
// exactly (the core proc also has a seed default parameter).
default_hash :: proc(data: []byte) -> u64 {
	return xxhash.XXH64(data)
}

// Options configures a Store at init.
Options :: struct {
	// chunk_size is the target size for chunks `insert` splits its
	// input into. Must be positive (asserted by `init`).
	chunk_size: int,
	// hash is the content hash used by the intern table; nil selects
	// `xxhash.XXH64`. Tests may substitute a degenerate hash (e.g. a
	// constant) to exercise the collision path.
	hash: Hash_Proc,
}

// chunk_header is the store's record of one published chunk.
chunk_header :: struct {
	data: []byte,
}

// intern_table is a small open-addressing hash table mapping content
// hashes to chunk ids (SPECS.md §7.1 interning). `hashes` and `ids` are
// parallel arrays whose length is the power-of-two capacity; a zero
// hash marks an empty slot (stored hashes are `h | 1`, so zero never
// collides with a stored entry).
intern_table :: struct {
	hashes: [dynamic]u64,
	ids:    [dynamic]Chunk_ID, // chunk index + 1; 0 = empty slot
	count:  int,
}

// Store owns immutable interned chunks. Contains dynamic arrays and
// must not be copied; treat it as a fixed-location value — pass by
// pointer, never by value.
Store :: struct {
	allocator:  runtime.Allocator,
	chunk_size: int,
	hash:       Hash_Proc,
	// chunks[i] is the data of chunk id i+1. Chunk data is immutable
	// once published and stays at a stable address for the store's
	// lifetime.
	chunks: [dynamic]chunk_header,
	total:  int, // sum of stored chunk lengths (bytes actually kept)
	table:  intern_table,
}

// init prepares `s` as an empty store. `options.chunk_size` must be
// positive (asserted: a programmer invariant, not external input).
// `options.hash` may be nil for the default (xxhash.XXH64). The store
// allocates nothing until the first insert. A Store must be destroyed
// before it is initialized again; init on a live store leaks.
init :: proc(s: ^Store, options: Options, allocator := context.allocator) {
	assert(options.chunk_size > 0, "chunk: options.chunk_size must be positive")
	s.allocator = allocator
	s.chunk_size = options.chunk_size
	s.hash = options.hash if options.hash != nil else default_hash
	s.chunks = make([dynamic]chunk_header, allocator)
	s.total = 0
	s.table = intern_table {
		hashes = make([dynamic]u64, allocator),
		ids    = make([dynamic]Chunk_ID, allocator),
		count  = 0,
	}
}

// destroy releases everything the store owns (chunk data, chunk index,
// intern table) and resets it to the zero state. With an arena
// allocator the individual frees are no-ops and the arena's `free_all`
// reclaims the memory (AGENTS.md §10.5). Destroy an initialized store
// exactly once, after every borrowed `data` view is done.
destroy :: proc(s: ^Store) {
	for h in s.chunks {
		if len(h.data) > 0 {
			mem.free(raw_data(h.data), s.allocator)
		}
	}
	delete(s.chunks)
	delete(s.table.hashes)
	delete(s.table.ids)
	s^ = Store{}
}

// insert stores `data` in the store: it is split into chunks of at most
// `chunk_size` bytes, each interned by content, and the id list of the
// chunks is returned in order — concatenating `data(ids[i])` for i in
// order reproduces `data` byte-for-byte.
//
// - `ids` is allocated with `allocator` and owned by the caller;
//   `delete` it when done (the list records the allocator). Empty
//   input returns an empty list with no error.
// - On error the store is left consistent: chunks interned before the
//   failure remain interned and reachable by later inserts of the same
//   content; the returned id list is empty (nothing to delete).
// - Errors are `.Resource_Limit` and their messages are allocated with
//   `allocator` — pass a healthy allocator, not the store's own, so
//   error creation cannot fail together with the store.
insert :: proc(
	s: ^Store,
	data: []byte,
	allocator := context.allocator,
) -> (
	ids: [dynamic]Chunk_ID,
	err: errs.Error,
) {
	n := len(data)
	if n == 0 {
		return {}, {}
	}
	k := (n - 1) / s.chunk_size + 1

	ids = make([dynamic]Chunk_ID, allocator)
	if aerr := reserve(&ids, k); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"chunk: reserving the %v-id result failed: %v",
			k,
			aerr,
			allocator = allocator,
		)
	}
	resize(&ids, k)

	for i in 0 ..< k {
		sub := data[i * s.chunk_size:min((i + 1) * s.chunk_size, n)]
		id, aerr := intern(s, sub)
		if aerr != .None {
			delete(ids)
			return {}, errs.newf(
				.Resource_Limit,
				"chunk: interning chunk %v of %v failed: %v",
				i,
				k,
				aerr,
				allocator = allocator,
			)
		}
		ids[i] = id
	}
	return ids, {}
}

// intern stores `data` as one chunk, returning the existing id when the
// content is already interned. It allocates only on a miss. Failures
// are raw allocator errors; `insert` translates them into structured
// errors with the caller's allocator.
intern :: proc(s: ^Store, data: []byte) -> (Chunk_ID, mem.Allocator_Error) {
	n := len(data)
	if n == 0 {
		return 0, .None
	}

	h := s.hash(data) | 1
	if idx, found := table_find(s, data, h); found {
		return s.table.ids[idx], .None
	}

	t := &s.table
	// Keep the load factor at most 3/4 so probing always finds an
	// empty slot.
	if (t.count + 1) * 4 > len(t.hashes) * 3 {
		if aerr := grow_table(s); aerr != .None {
			return 0, aerr
		}
	}

	chunk_bytes, aerr := mem.alloc_bytes(n, 1, s.allocator)
	if aerr != .None {
		return 0, aerr
	}
	copy(chunk_bytes, data)

	if rerr := reserve(&s.chunks, len(s.chunks) + 1); rerr != .None {
		mem.free(raw_data(chunk_bytes), s.allocator)
		return 0, rerr
	}
	resize(&s.chunks, len(s.chunks) + 1)
	s.chunks[len(s.chunks) - 1] = chunk_header{data = chunk_bytes}
	s.total += n
	id := Chunk_ID(len(s.chunks))

	// Publish in the intern table. Capacity was ensured above and the
	// content is known absent, so this cannot fail. (The chunk is
	// already in `s.chunks`, so probing with content comparison — as
	// `table_find` does — would now find it; probe hashes only.)
	mask := u64(len(t.hashes) - 1)
	i := int(h & mask)
	for t.hashes[i] != 0 {
		i = (i + 1) & int(mask)
	}
	t.hashes[i] = h
	t.ids[i] = id
	t.count += 1
	return id, .None
}

// table_find looks up `data` (hashed to `h`) in the intern table with
// linear probing. On a miss it returns the first empty slot, which the
// caller may use for insertion once capacity is ensured.
table_find :: proc(s: ^Store, data: []byte, h: u64) -> (idx: int, found: bool) {
	t := &s.table
	cap := len(t.hashes)
	if cap == 0 {
		return 0, false
	}
	mask := u64(cap - 1)
	i := int(h & mask)
	for {
		if t.hashes[i] == 0 {
			return i, false
		}
		if t.hashes[i] == h && bytes.equal(s.chunks[int(t.ids[i]) - 1].data, data) {
			return i, true
		}
		i = (i + 1) & int(mask)
	}
}

// grow_table doubles the intern table capacity (16 when empty),
// rehashing every entry. On failure the old table is untouched. With
// an arena allocator the old arrays' frees are no-ops and their memory
// stays until `free_all`.
grow_table :: proc(s: ^Store) -> mem.Allocator_Error {
	t := &s.table
	old_cap := len(t.hashes)
	new_cap := 16 if old_cap == 0 else old_cap * 2
	if new_cap <= old_cap {
		return .Out_Of_Memory
	}

	new_hashes := make([dynamic]u64, s.allocator)
	new_ids := make([dynamic]Chunk_ID, s.allocator)
	if aerr := resize(&new_hashes, new_cap); aerr != .None {
		return aerr
	}
	if aerr := resize(&new_ids, new_cap); aerr != .None {
		delete(new_hashes)
		return aerr
	}

	mask := u64(new_cap - 1)
	for i in 0 ..< old_cap {
		h := t.hashes[i]
		if h == 0 {
			continue
		}
		j := int(h & mask)
		for new_hashes[j] != 0 {
			j = (j + 1) & int(mask)
		}
		new_hashes[j] = h
		new_ids[j] = t.ids[i]
	}

	delete(t.hashes)
	delete(t.ids)
	t.hashes = new_hashes
	t.ids = new_ids
	return .None
}

// data returns the immutable content of chunk `id`, borrowed for the
// store's lifetime. The nil id (0) returns an empty slice. Any other
// id not produced by this store is a programmer error and asserts.
data :: proc(s: ^Store, id: Chunk_ID) -> []byte {
	if id == 0 {
		return {}
	}
	assert(int(id) > 0 && int(id) <= len(s.chunks), "chunk: invalid chunk id")
	return s.chunks[int(id) - 1].data
}

// chunk_size returns the target chunk size the store splits at.
chunk_size :: proc(s: ^Store) -> int {
	return s.chunk_size
}

// chunk_count returns the number of published chunks (interned misses).
chunk_count :: proc(s: ^Store) -> int {
	return len(s.chunks)
}

// total_bytes returns the number of bytes actually stored (the sum of
// published chunk lengths; re-inserted content does not add to it).
total_bytes :: proc(s: ^Store) -> int {
	return s.total
}
