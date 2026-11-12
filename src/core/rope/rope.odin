// Package rope: leaves, metrics, and range iteration (M02.02).
//
// The second layer of the persistent piece-rope (SPECS.md §7.1), on
// top of the immutable chunk store (`core/chunk`):
//
// ```text
// Piece        store_id + byte_start + byte_length   (a view of a chunk)
// Leaf         a small fixed-capacity collection of pieces + local metrics
// Sequence     an ordered leaf list + total metrics (the M02.02 shape;
//              M02.03 wraps it in a balanced tree with persistent roots)
// ```
//
// Contracts:
//
// - **Never flatten for a range.** `read`/`read_all`/`Span_Iter` walk
//   pieces and copy only the requested bytes; span iteration yields
//   borrowed slices of the immutable chunk store (stable for the
//   store's lifetime).
// - **Metrics.** Every piece contributes byte count, Unicode scalar
//   count, LF count, and lone-CR count, plus boundary state so that a
//   CRLF split across a piece boundary counts as one break and a
//   multi-byte scalar split across a boundary counts as one scalar
//   (SPECS.md §7.2). `combine` is the boundary-aware merge; folding a
//   sequence's leaf metrics must equal `metrics_of` of the flattened
//   text — the property tests enforce this. Grapheme counts are
//   deliberately absent (SPECS.md §7.2: grapheme rules need context).
//   Scalar counting is a deterministic length model, not full Unicode
//   validation: 0xC2..DF/0xE0..EF/0xF0..F4 sequences with their
//   continuation bytes count one scalar, every other byte counts one;
//   validation belongs to the file codec (M03.03) and console decoder
//   (M10.01), which must keep this counting contract in sync.
// - **Ownership.** The leaf pool (`core:container/pool`, intrusive
//   `link` field, virtual-arena backed, libc-free) owns the leaves;
//   the caller-provided allocator owns the leaf-pointer list and error
//   messages. `sequence_destroy` drops both. Leaves carry no nested
//   allocations. The referenced chunk store must outlive the sequence.
// - **Single owner.** A `Sequence` contains a pool with internal locks
//   and must not be copied; pass it by pointer, use it from one
//   mutator thread (AGENTS.md §13). Span data is immutable chunk
//   storage and may be read elsewhere per the chunk contract.
//
// Backend-free: imports only `core:` packages plus `core/chunk` and
// `core/errs` — no Sokol collection (SPECS.md §4.2), builds under
// `-no-crt`.
package rope

import pool "core:container/pool"
import "core:mem"

import chunk "../chunk"
import errs "../errs"

// MAX_PIECES_PER_LEAF is the fixed piece capacity of a leaf. Fixed
// capacity keeps every leaf the same size for the pool and avoids
// per-leaf allocation.
MAX_PIECES_PER_LEAF :: 8

// DEFAULT_TARGET_LEAF_BYTES is the default soft maximum content size
// of a leaf; the builder closes a leaf when appending would exceed it.
DEFAULT_TARGET_LEAF_BYTES :: 16 * 1024

// Piece is a view of a chunk's content (SPECS.md §7.1): `store_id` is
// a chunk id in the sequence's chunk store, `byte_start`/`byte_length`
// select a non-empty byte range inside that chunk.
Piece :: struct {
	store_id:   chunk.Chunk_ID,
	byte_start: int,
	byte_length: int,
}

// Byte_Range selects a byte range of a sequence: `start` inclusive,
// `end` exclusive, 0 <= start <= end <= byte_count.
Byte_Range :: struct {
	start: int,
	end:   int,
}

// Boundary carries the state a metrics combine needs across the join
// of two adjacent runs (SPECS.md §7.2: "boundary summaries").
Boundary :: struct {
	// leading_continuations is the number of UTF-8 continuation bytes
	// (0x80..0xBF) at the start of the run, capped at 3 — the longest
	// tail a previous run can need to complete.
	leading_continuations: u8,
	// tail_expects is the number of continuation bytes still needed to
	// complete a multi-byte scalar whose lead (and some continuations)
	// end the run; 0..3. The incomplete scalar was already counted
	// provisionally as one scalar.
	tail_expects: u8,
	// starts_with_lf / ends_with_cr carry the CRLF state across the
	// boundary: a '\r' at the end of the left run followed by a '\n'
	// at the start of the right run is one break, not two.
	starts_with_lf: bool,
	ends_with_cr:   bool,
}

// Metrics is the cached per-node summary (SPECS.md §7.2). `lf_count`
// counts '\n' bytes; `lone_cr_count` counts '\r' bytes not followed by
// '\n' (a trailing '\r' counts provisionally and is resolved by
// `combine`); `line_break_count` is their sum. Grapheme counts are
// intentionally absent.
Metrics :: struct {
	byte_count:    int,
	scalar_count:  int,
	lf_count:      int,
	lone_cr_count: int,
	boundary:      Boundary,
}

// line_break_count returns the number of line breaks: each LF and each
// lone CR (a CRLF pair is one break).
line_break_count :: proc(m: Metrics) -> int {
	return m.lf_count + m.lone_cr_count
}

// Leaf is a pool-allocated node holding up to MAX_PIECES_PER_LEAF
// pieces and their combined metrics. The intrusive `link` field is the
// pool's free-list link (pool.init(&p, "link")); the pool zeroes
// recycled leaves.
Leaf :: struct {
	link:    ^Leaf,
	pieces:  [MAX_PIECES_PER_LEAF]Piece,
	count:   int,
	metrics: Metrics,
}

// Options configures a Sequence at init.
Options :: struct {
	// target_leaf_bytes is the soft maximum content size of a leaf:
	// the builder closes a leaf when appending a piece would exceed it
	// (an oversized single piece gets its own leaf). 0 selects
	// DEFAULT_TARGET_LEAF_BYTES.
	target_leaf_bytes: int,
}

// Sequence is an ordered, immutable text run built from pieces
// (M02.02's flat shape). Contains a pool with internal locks; treat it
// as a fixed-location value — pass by pointer, never by value.
Sequence :: struct {
	store:  ^chunk.Store, // borrowed; must outlive the sequence
	target: int, // target leaf content size
	pool:   pool.Pool(Leaf),
	leaves: [dynamic]^Leaf, // owned references into the pool
	total:  Metrics,
}

// sequence_init prepares `s` as an empty sequence over `store`.
// `options.target_leaf_bytes` must be non-negative (asserted: a
// programmer invariant); 0 selects the default. The caller-provided
// allocator backs the leaf-pointer list and error messages; the pool
// manages its own (virtual-arena) memory. A Sequence must be destroyed
// before it is initialized again.
sequence_init :: proc(
	s: ^Sequence,
	store: ^chunk.Store,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	assert(store != nil, "rope: nil chunk store")
	assert(options.target_leaf_bytes >= 0, "rope: negative target_leaf_bytes")
	s.store = store
	s.target = options.target_leaf_bytes if options.target_leaf_bytes > 0 else DEFAULT_TARGET_LEAF_BYTES
	s.total = {}
	s.leaves = make([dynamic]^Leaf, allocator)
	if aerr := pool.init(&s.pool, "link"); aerr != .None {
		delete(s.leaves)
		return errs.newf(
			.Resource_Limit,
			"rope: leaf pool init failed: %v",
			aerr,
			allocator = allocator,
		)
	}
	return {}
}

// sequence_destroy releases the sequence: the leaf-pointer list (with
// the init allocator) and the pool's leaf storage. Leaves are dropped
// wholesale — they hold no nested allocations. With an arena allocator
// the list free is a no-op and `free_all` reclaims it; the pool's own
// arena is released by `pool.destroy` itself. Destroy after every
// borrowed span is done.
sequence_destroy :: proc(s: ^Sequence) {
	delete(s.leaves)
	pool.destroy(&s.pool)
	s^ = Sequence{}
}

// append_data stores `data` in the sequence: it is interned in the
// chunk store (split at the store's chunk size), then appended piece
// by piece into leaves. Appending empty data is a no-op. On error the
// sequence keeps everything appended before the failure and stays
// consistent; the error message is allocated with `allocator`.
append_data :: proc(s: ^Sequence, data: []byte, allocator := context.allocator) -> errs.Error {
	if len(data) == 0 {
		return {}
	}
	ids, cerr := chunk.insert(s.store, data, allocator)
	if !errs.ok(cerr) {
		return cerr
	}
	defer delete(ids)
	for id in ids {
		d := chunk.data(s.store, id)
		p := Piece{store_id = id, byte_start = 0, byte_length = len(d)}
		if perr := append_piece(s, p, allocator); !errs.ok(perr) {
			return perr
		}
	}
	return {}
}

// append_piece appends one piece to the sequence, validating it
// against the chunk store (unknown chunk id, non-positive length, or a
// range outside the chunk are `.Invalid_Input`) and updating the leaf
// and sequence metrics. A new leaf is allocated (pool + list growth)
// when the current one is full; those failures are `.Resource_Limit`.
append_piece :: proc(s: ^Sequence, p: Piece, allocator := context.allocator) -> errs.Error {
	cd, found := chunk.lookup(s.store, p.store_id)
	if !found {
		return errs.newf(
			.Invalid_Input,
			"rope: piece references unknown chunk id %v",
			p.store_id,
			allocator = allocator,
		)
	}
	if p.byte_length <= 0 {
		return errs.newf(
			.Invalid_Input,
			"rope: piece byte_length %v is not positive",
			p.byte_length,
			allocator = allocator,
		)
	}
	if p.byte_start < 0 || p.byte_start + p.byte_length > len(cd) {
		return errs.newf(
			.Invalid_Input,
			"rope: piece range [%v, %v) exceeds chunk length %v",
			p.byte_start,
			p.byte_start + p.byte_length,
			len(cd),
			allocator = allocator,
		)
	}
	pm := metrics_of(cd[p.byte_start:p.byte_start + p.byte_length])

	leaf: ^Leaf
	last := len(s.leaves) - 1
	if last >= 0 && !leaf_is_full(s, s.leaves[last], pm) {
		leaf = s.leaves[last]
	} else {
		new_leaf, aerr := pool.get(&s.pool)
		if aerr != .None {
			return errs.newf(
				.Resource_Limit,
				"rope: allocating a leaf failed: %v",
				aerr,
				allocator = allocator,
			)
		}
		if rerr := reserve(&s.leaves, len(s.leaves) + 1); rerr != .None {
			pool.put(&s.pool, new_leaf)
			return errs.newf(
				.Resource_Limit,
				"rope: growing the leaf list failed: %v",
				rerr,
				allocator = allocator,
			)
		}
		resize(&s.leaves, len(s.leaves) + 1)
		s.leaves[len(s.leaves) - 1] = new_leaf
		leaf = new_leaf
	}

	leaf.pieces[leaf.count] = p
	leaf.count += 1
	leaf.metrics = combine(leaf.metrics, pm)
	s.total = combine(s.total, pm)
	return {}
}

// leaf_is_full reports whether appending a piece with metrics `pm`
// would overflow the leaf's capacity: the fixed piece count, or the
// target content size (an empty leaf always accepts its first piece,
// even one larger than the target).
leaf_is_full :: proc(s: ^Sequence, leaf: ^Leaf, pm: Metrics) -> bool {
	if leaf.count >= MAX_PIECES_PER_LEAF {
		return true
	}
	return leaf.count > 0 && leaf.metrics.byte_count + pm.byte_count > s.target
}

// read copies bytes from `range` into `out`, up to len(out), and
// returns the number copied. A range outside [0, byte_count] is
// `.Invalid_Input`; a short `out` is not an error — callers loop with
// an advanced range. Nothing is flattened: only the touched pieces are
// read.
read :: proc(
	s: ^Sequence,
	range: Byte_Range,
	out: []byte,
	allocator := context.allocator,
) -> (int, errs.Error) {
	it: Span_Iter
	if ierr := span_iter_init(&it, s, range, allocator); !errs.ok(ierr) {
		return 0, ierr
	}
	n := 0
	for n < len(out) {
		span, more := span_iter_next(&it, s)
		if !more {
			break
		}
		c := min(len(span), len(out) - n)
		copy(out[n:], span[:c])
		n += c
		if c < len(span) {
			break // out is full mid-span
		}
	}
	return n, {}
}

// read_all copies the whole `range` into a fresh buffer allocated with
// `allocator` (caller-owned; delete it when done). A range outside
// [0, byte_count] is `.Invalid_Input`.
read_all :: proc(
	s: ^Sequence,
	range: Byte_Range,
	allocator := context.allocator,
) -> ([]byte, errs.Error) {
	if ierr := validate_range(s, range, allocator); !errs.ok(ierr) {
		return {}, ierr
	}
	n := range.end - range.start
	out, aerr := mem.alloc_bytes(n, 1, allocator)
	if aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: allocating %v bytes for a read failed: %v",
			n,
			aerr,
			allocator = allocator,
		)
	}
	copied, rerr := read(s, range, out, allocator)
	if !errs.ok(rerr) {
		mem.free(raw_data(out), allocator)
		return {}, rerr
	}
	return out[:copied], {}
}

// metrics returns the sequence's total metrics.
metrics :: proc(s: ^Sequence) -> Metrics {
	return s.total
}

// byte_count returns the sequence's total byte count.
byte_count :: proc(s: ^Sequence) -> int {
	return s.total.byte_count
}

// leaf_count returns the number of leaves.
leaf_count :: proc(s: ^Sequence) -> int {
	return len(s.leaves)
}

// leaf_at returns leaf `i` (asserts in range). Leaves are immutable
// once published; M02.03 reads pieces/metrics through this.
leaf_at :: proc(s: ^Sequence, i: int) -> ^Leaf {
	assert(i >= 0 && i < len(s.leaves), "rope: leaf index out of range")
	return s.leaves[i]
}

// piece_count returns the total number of pieces.
piece_count :: proc(s: ^Sequence) -> int {
	n := 0
	for leaf in s.leaves {
		n += leaf.count
	}
	return n
}

// Span_Iter walks the pieces of a byte range piece by piece. Each span
// is a borrowed slice of immutable chunk storage.
Span_Iter :: struct {
	leaf:      int, // leaf index
	piece:     int, // piece index within the leaf
	off_piece: int, // byte offset within the current piece
	remaining: int, // bytes left in the requested range
}

// span_iter_init validates `range` and positions the iterator at its
// start. A range outside [0, byte_count] is `.Invalid_Input`; an empty
// range yields an iterator that immediately reports done.
span_iter_init :: proc(
	it: ^Span_Iter,
	s: ^Sequence,
	range: Byte_Range,
	allocator := context.allocator,
) -> errs.Error {
	if ierr := validate_range(s, range, allocator); !errs.ok(ierr) {
		return ierr
	}
	it^ = Span_Iter{}
	it.remaining = range.end - range.start
	if it.remaining == 0 {
		return {}
	}

	// Seek to the leaf containing range.start.
	skip := range.start
	for it.leaf < len(s.leaves) {
		if skip < s.leaves[it.leaf].metrics.byte_count {
			break
		}
		skip -= s.leaves[it.leaf].metrics.byte_count
		it.leaf += 1
	}
	assert(it.leaf < len(s.leaves), "rope: validated range must fall inside a leaf")

	// Seek to the piece containing the remainder.
	for {
		leaf := s.leaves[it.leaf]
		if it.piece < leaf.count && skip < leaf.pieces[it.piece].byte_length {
			break
		}
		skip -= leaf.pieces[it.piece].byte_length
		it.piece += 1
	}
	it.off_piece = skip
	return {}
}

// span_iter_next returns the next span of the range (a slice of chunk
// storage) and whether one exists. Spans never exceed the requested
// range and never cross piece boundaries.
span_iter_next :: proc(it: ^Span_Iter, s: ^Sequence) -> (span: []byte, more: bool) {
	if it.remaining == 0 {
		return {}, false
	}
	leaf := s.leaves[it.leaf]
	p := leaf.pieces[it.piece]
	cd := chunk.data(s.store, p.store_id)
	n := min(it.remaining, p.byte_length - it.off_piece)
	span = cd[p.byte_start + it.off_piece:p.byte_start + it.off_piece + n]
	it.remaining -= n
	it.off_piece += n
	if it.off_piece == p.byte_length {
		it.off_piece = 0
		it.piece += 1
		if it.piece >= leaf.count {
			it.piece = 0
			it.leaf += 1
		}
	}
	return span, true
}

// validate_range checks that `range` lies inside [0, byte_count].
validate_range :: proc(s: ^Sequence, r: Byte_Range, allocator := context.allocator) -> errs.Error {
	if r.start < 0 || r.end < r.start || r.end > s.total.byte_count {
		return errs.newf(
			.Invalid_Input,
			"rope: range [%v, %v) outside [0, %v)",
			r.start,
			r.end,
			s.total.byte_count,
			allocator = allocator,
		)
	}
	return {}
}

// combine merges the metrics of two adjacent runs a+b, resolving
// boundary effects:
//
// - a multi-byte scalar split across the boundary counts once: the
//   min of a's pending tail and b's leading continuations was counted
//   provisionally on both sides and is subtracted;
// - a CRLF split across the boundary is one break: a's trailing lone
//   CR stops being lone when b starts with LF;
// - the merged boundary state comes from the non-empty side(s) —
//   except when b consists entirely of continuation bytes that merge
//   into a's pending scalar: the pending tail then carries over with
//   `a.tail_expects - b.leading_continuations` continuations still
//   needed.
//
// combine is associative over runs produced by `metrics_of`; the
// property tests compare folded combines against `metrics_of` of the
// flattened text.
combine :: proc(a, b: Metrics) -> Metrics {
	tail := b.boundary.tail_expects
	if b.byte_count == 0 {
		tail = a.boundary.tail_expects
	} else if a.byte_count > 0 && a.boundary.tail_expects > 0 &&
	   int(b.boundary.leading_continuations) == b.byte_count &&
	   b.boundary.leading_continuations < a.boundary.tail_expects {
		// b is nothing but continuation bytes merging into a's pending
		// scalar (b's leading run is all of b, and the scalar still
		// needs more).
		tail = a.boundary.tail_expects - b.boundary.leading_continuations
	}
	return Metrics {
		byte_count = a.byte_count + b.byte_count,
		scalar_count = a.scalar_count + b.scalar_count -
			int(min(a.boundary.tail_expects, b.boundary.leading_continuations)),
		lf_count = a.lf_count + b.lf_count,
		lone_cr_count = a.lone_cr_count + b.lone_cr_count -
			(1 if a.boundary.ends_with_cr && b.boundary.starts_with_lf else 0),
		boundary = Boundary {
			leading_continuations = a.boundary.leading_continuations if a.byte_count > 0 else b.boundary.leading_continuations,
			tail_expects = tail,
			starts_with_lf = a.boundary.starts_with_lf if a.byte_count > 0 else b.boundary.starts_with_lf,
			ends_with_cr = b.boundary.ends_with_cr if b.byte_count > 0 else a.boundary.ends_with_cr,
		},
	}
}

// metrics_of computes the metrics of a standalone byte run (no carry
// into or out of it): bytes, scalars, LF, lone CR, and the boundary
// state for merging. The scalar model: a lead in 0xC2..DF/0xE0..EF/
// 0xF0..F4 followed by its full set of continuation bytes is one
// scalar; every other byte is one scalar (stray continuations and
// invalid leads included); an incomplete trailing sequence is one
// provisional scalar whose missing continuations become `tail_expects`
// (resolved by `combine`). Line breaks: each '\n' is one; each '\r'
// not followed by '\n' within the run is one (a trailing '\r' is
// provisional, resolved by `combine`).
metrics_of :: proc(data: []byte) -> Metrics {
	m := Metrics{byte_count = len(data)}
	if len(data) == 0 {
		return m
	}

	i := 0
	for i < 3 && i < len(data) && is_continuation(data[i]) {
		i += 1
	}
	m.boundary.leading_continuations = u8(i)
	m.boundary.starts_with_lf = data[0] == '\n'
	m.boundary.ends_with_cr = data[len(data) - 1] == '\r'

	for j := 0; j < len(data); j += 1 {
		b := data[j]
		if b == '\n' {
			m.scalar_count += 1
			m.lf_count += 1
			continue
		}
		if b < 0x80 {
			m.scalar_count += 1
			if b == '\r' {
				// Lone unless the next byte is LF (a trailing CR is
				// provisional; combine resolves it).
				if j + 1 == len(data) || data[j + 1] != '\n' {
					m.lone_cr_count += 1
				}
			}
			continue
		}

		expect := 0
		ok := true
		if b >= 0xC2 && b <= 0xDF {
			expect = 1
		} else if b >= 0xE0 && b <= 0xEF {
			expect = 2
		} else if b >= 0xF0 && b <= 0xF4 {
			expect = 3
		} else {
			ok = false
		}
		if !ok {
			// Stray continuation or invalid lead byte: one scalar.
			m.scalar_count += 1
			continue
		}
		n := 0
		for n < expect && j + 1 + n < len(data) && is_continuation(data[j + 1 + n]) {
			n += 1
		}
		if n == expect {
			m.scalar_count += 1
			j += expect
		} else if j + 1 + n == len(data) {
			// Truncated at the end: one provisional scalar; the missing
			// continuations are the tail state.
			m.scalar_count += 1
			m.boundary.tail_expects = u8(expect - n)
			j += n
		} else {
			// Lead broken by a non-continuation before the end.
			m.scalar_count += 1
			j += n
		}
	}
	return m
}

// is_continuation reports whether `b` is a UTF-8 continuation byte.
is_continuation :: proc(b: u8) -> bool {
	return b >= 0x80 && b <= 0xBF
}
