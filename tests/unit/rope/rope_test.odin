// Tests for the rope leaves/metrics/iteration layer (M02.02):
// `hammer:core/rope` — piece/leaf/metric models, boundary-aware
// metric combining (CRLF and split multi-byte scalars), sequence
// building with leaf splitting, byte-range reads without flattening,
// span iteration, validation errors, arena lifetime, allocation
// failure, and a randomized differential property against a reference
// byte model.
package rope_test

import "core:bytes"
import "core:fmt"
import "core:testing"
import mem_virtual "core:mem/virtual"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import rope "hammer:core/rope"

// bytes_of converts a string to a byte slice (repo idiom for literals).
bytes_of :: proc(text: string) -> []byte {
	return transmute([]byte)text
}

// append_text appends `text` to the sequence, expecting success.
append_text :: proc(t: ^testing.T, s: ^rope.Sequence, text: string) {
	err := rope.append_data(s, bytes_of(text))
	if !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		defer delete(desc, context.allocator)
		errs.destroy(&err)
		testing.expectf(t, false, "append(%q) failed: %s", text, desc)
	}
}

// expect_range_error asserts that reading `range` fails with
// .Invalid_Input.
expect_range_error :: proc(t: ^testing.T, s: ^rope.Sequence, range: rope.Byte_Range) {
	_, err := rope.read_all(s, range)
	defer errs.destroy(&err)
	testing.expectf(
		t,
		err.kind == .Invalid_Input,
		"range %v: expected .Invalid_Input, got %v",
		range,
		err.kind,
	)
}

// expect_metrics asserts full struct equality with a helpful message.
expect_metrics :: proc(t: ^testing.T, got, want: rope.Metrics, what: string) {
	testing.expectf(
		t,
		got == want,
		"%s: got %v, want %v",
		what,
		got,
		want,
	)
}

// test_metrics_of pins the standalone decode model: bytes, scalars,
// LF, lone CR, and boundary state.
@(test)
test_metrics_of :: proc(t: ^testing.T) {
	m := rope.metrics_of(bytes_of("abc\n"))
	expect_metrics(t, m, rope.Metrics{byte_count = 4, scalar_count = 4, lf_count = 1}, "abc\\n")
	testing.expect(t, rope.line_break_count(m) == 1)

	m = rope.metrics_of(bytes_of("é€✓"))
	expect_metrics(t, m, rope.Metrics{byte_count = 8, scalar_count = 3}, "é€✓")

	m = rope.metrics_of(bytes_of("a\r\nb\n"))
	expect_metrics(t, m, rope.Metrics{byte_count = 5, scalar_count = 5, lf_count = 2}, "a\\r\\nb\\n")
	testing.expect(t, rope.line_break_count(m) == 2, "CRLF is one break")

	m = rope.metrics_of(bytes_of("a\rb"))
	expect_metrics(t, m, rope.Metrics{byte_count = 3, scalar_count = 3, lone_cr_count = 1}, "a\\rb")
	testing.expect(t, rope.line_break_count(m) == 1, "lone CR is one break")

	m = rope.metrics_of({'\r'})
	testing.expect(t, m.boundary.ends_with_cr)
	testing.expect(t, m.lone_cr_count == 1, "trailing CR is provisionally lone")

	m = rope.metrics_of({'\n'})
	testing.expect(t, m.boundary.starts_with_lf)
	testing.expect(t, m.lf_count == 1)

	// Invalid bytes: stray continuation and invalid lead each count
	// one scalar; a leading continuation is boundary state.
	m = rope.metrics_of({0x80, 0xFF, 'a'})
	testing.expect(t, m.scalar_count == 3)
	testing.expect(t, m.boundary.leading_continuations == 1)

	// Truncated multi-byte scalars at the end become provisional
	// scalars with tail state.
	m = rope.metrics_of(bytes_of("é")[:1])
	testing.expect(t, m.scalar_count == 1)
	testing.expect(t, m.boundary.tail_expects == 1)
	m = rope.metrics_of({0xF0, 0x9F, 0x98})
	testing.expect(t, m.scalar_count == 1 && m.boundary.tail_expects == 1, "truncated emoji")

	m = rope.metrics_of({})
	testing.expect(t, m == rope.Metrics{}, "empty run has zero metrics")
}

// test_combine_split_invariance checks that combining at every split
// point of a text equals decoding it whole — the boundary rules must
// be exact for CRLF and multi-byte scalars.
@(test)
test_combine_split_invariance :: proc(t: ^testing.T) {
	texts := []string{
		"a\r\nb",
		"xé€y",
		"😀中\r\nz",
		"line1\nline2\r\n",
		"x\r\r\ny",
		"é",
		"trailing\r",
		"leading\n",
		"\xF0\x9F", // pending 4-byte lead + one continuation
		"\xE2\x82\x82", // invalid: lead followed by two continuations
	}
	for text in texts {
		data := bytes_of(text)
		whole := rope.metrics_of(data)
		for split in 0 ..= len(data) {
			combined := rope.combine(rope.metrics_of(data[:split]), rope.metrics_of(data[split:]))
			expect_metrics(t, combined, whole, fmt.tprintf("%q split at %v", text, split))
		}
	}

	// A scalar completed across the boundary counts once (€ = E2 82 AC
	// split 1+2 bytes).
	a := rope.metrics_of({0xE2})
	b := rope.metrics_of({0x82, 0xAC, 'x'})
	expect_metrics(t, rope.combine(a, b), rope.metrics_of({0xE2, 0x82, 0xAC, 'x'}), "completed across boundary")

	// A broken completion keeps both sides' provisional counts
	// (0xE2 expects two continuations; 0x82 is followed by 'x').
	c := rope.metrics_of({0xE2})
	d := rope.metrics_of({0x82, 'x'})
	expect_metrics(t, rope.combine(c, d), rope.metrics_of({0xE2, 0x82, 'x'}), "broken across boundary")

	// The pending tail carries over when the right run is entirely
	// continuation bytes: E2 | 82 | AC is one scalar (€) however it is
	// grouped.
	ab := rope.combine(rope.metrics_of({0xE2}), rope.metrics_of({0x82}))
	testing.expect(t, ab.boundary.tail_expects == 1, "tail must carry over an all-continuation run")
	expect_metrics(t, rope.combine(ab, rope.metrics_of({0xAC})), rope.metrics_of({0xE2, 0x82, 0xAC}), "tail carry")
}

// test_append_and_flatten builds a sequence from several appends (and
// an empty one) and verifies flattening and metrics against the
// concatenated reference.
@(test)
test_append_and_flatten :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 8})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {})))
	defer rope.sequence_destroy(&s)

	append_text(t, &s, "hello ")
	append_text(t, &s, "")
	append_text(t, &s, "wörld\r\n")
	append_text(t, &s, "second line\n")

	ref := "hello wörld\r\nsecond line\n"
	testing.expect(t, rope.byte_count(&s) == len(ref))

	got, err := rope.read_all(&s, rope.Byte_Range{0, rope.byte_count(&s)})
	defer delete(got)
	testing.expect(t, errs.ok(err))
	testing.expect(t, bytes.equal(got, bytes_of(ref)), "flatten must reproduce the input")

	expect_metrics(t, rope.metrics(&s), rope.metrics_of(bytes_of(ref)), "total metrics")
}

// test_leaf_piece_capacity builds with a chunk size small enough that
// leaves fill by piece count before bytes.
@(test)
test_leaf_piece_capacity :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 2})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {target_leaf_bytes = 100})))
	defer rope.sequence_destroy(&s)

	// 20 pieces of 2 bytes: leaves hold at most 8 pieces.
	append_text(t, &s, "abcdefghijklmnopqrstuvwxyz0123456789ABCD")
	testing.expect(t, rope.piece_count(&s) == 20)
	testing.expect(t, rope.leaf_count(&s) == 3)
	for i in 0 ..< 3 {
		count := rope.leaf_at(&s, i).count
		testing.expectf(t, count <= rope.MAX_PIECES_PER_LEAF, "leaf %v has %v pieces", i, count)
	}
	testing.expect(t, rope.leaf_at(&s, 0).count == 8)
	testing.expect(t, rope.leaf_at(&s, 1).count == 8)
	testing.expect(t, rope.leaf_at(&s, 2).count == 4)
}

// test_leaf_byte_bound builds with a small byte target so leaves close
// by content size, and recomputes every leaf's metrics from its pieces.
@(test)
test_leaf_byte_bound :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 8})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {target_leaf_bytes = 24})))
	defer rope.sequence_destroy(&s)

	// 200 bytes -> 25 pieces of 8 -> leaves of at most 24 bytes each.
	text := ""
	for i in 0 ..< 200 {
		text = fmt.tprintf("%s%c", text, 'a' + (i % 26))
	}
	append_text(t, &s, text)
	testing.expect(t, rope.piece_count(&s) == 25)

	total := rope.Metrics{}
	for i in 0 ..< rope.leaf_count(&s) {
		leaf := rope.leaf_at(&s, i)
		testing.expect(t, leaf.count >= 1 && leaf.count <= rope.MAX_PIECES_PER_LEAF)
		testing.expectf(t, leaf.metrics.byte_count <= 24, "leaf %v has %v bytes", i, leaf.metrics.byte_count)

		// Recompute the leaf metrics from its pieces; they must match.
		m := rope.Metrics{}
		for j in 0 ..< leaf.count {
			p := leaf.pieces[j]
			d := chunk.data(&store, p.store_id)
			m = rope.combine(m, rope.metrics_of(d[p.byte_start:p.byte_start + p.byte_length]))
		}
		expect_metrics(t, leaf.metrics, m, "leaf metrics recompute")
		total = rope.combine(total, leaf.metrics)
	}
	expect_metrics(t, rope.metrics(&s), total, "folded leaf metrics vs sequence total")
	expect_metrics(t, rope.metrics(&s), rope.metrics_of(bytes_of(text)), "total vs reference")
}

// test_read_partial pins the partial-fill contract: short buffers loop
// until the range is consumed; oversized buffers fill exactly.
@(test)
test_read_partial :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 4})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {})))
	defer rope.sequence_destroy(&s)

	ref := "0123456789abcdefghij"
	append_text(t, &s, ref)

	r := rope.Byte_Range{3, 17}
	want := bytes_of(ref)[3:17]

	// Loop with a small buffer.
	got := make([dynamic]u8, context.allocator)
	defer delete(got)
	buf: [5]u8
	pos := r.start
	for pos < r.end {
		n, err := rope.read(&s, rope.Byte_Range{pos, r.end}, buf[:])
		testing.expect(t, errs.ok(err))
		testing.expectf(t, n > 0, "read at %v must make progress", pos)
		append(&got, ..buf[:n])
		pos += n
	}
	testing.expect(t, bytes.equal(got[:], want), "looped partial reads must reproduce the range")

	// Oversized buffer fills exactly the range.
	big := make([]byte, 100, context.allocator)
	defer delete(big, context.allocator)
	n, err := rope.read(&s, r, big)
	testing.expect(t, errs.ok(err))
	testing.expect(t, n == r.end - r.start)
	testing.expect(t, bytes.equal(big[:n], want))

	// Empty output is fine.
	n, err = rope.read(&s, r, {})
	testing.expect(t, errs.ok(err) && n == 0)

	// Empty range is fine.
	n, err = rope.read(&s, rope.Byte_Range{5, 5}, buf[:])
	testing.expect(t, errs.ok(err) && n == 0)

	// Out-of-bounds ranges are .Invalid_Input.
	expect_range_error(t, &s, rope.Byte_Range{-1, 4})
	expect_range_error(t, &s, rope.Byte_Range{4, 3})
	expect_range_error(t, &s, rope.Byte_Range{0, 100})
}

// test_span_iteration collects spans over a range crossing several
// pieces and leaves and compares against the reference slice.
@(test)
test_span_iteration :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 3})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {target_leaf_bytes = 6})))
	defer rope.sequence_destroy(&s)

	ref := "abcdefghijklmnopqrstuvwxyz"
	append_text(t, &s, ref)

	r := rope.Byte_Range{5, 21}
	got := make([dynamic]u8, context.allocator)
	defer delete(got)

	it: rope.Span_Iter
	testing.expect(t, errs.ok(rope.span_iter_init(&it, &s, r)))
	for {
		span, more := rope.span_iter_next(&it, &s)
		if !more {
			break
		}
		testing.expect(t, len(span) > 0, "spans must be non-empty")
		append(&got, ..span)
	}
	testing.expect(t, bytes.equal(got[:], bytes_of(ref)[5:21]), "spans must reproduce the range")

	// An empty range yields no spans.
	testing.expect(t, errs.ok(rope.span_iter_init(&it, &s, rope.Byte_Range{7, 7})))
	_, more := rope.span_iter_next(&it, &s)
	testing.expect(t, !more)

	// An invalid range is rejected.
	err := rope.span_iter_init(&it, &s, rope.Byte_Range{0, 999})
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
}

// test_append_piece_validation feeds invalid pieces and checks the
// sequence rejects them without changing state, then appends a valid
// subrange piece manually.
@(test)
test_append_piece_validation :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 64})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {})))
	defer rope.sequence_destroy(&s)

	append_text(t, &s, "hello world")
	valid_id := rope.leaf_at(&s, 0).pieces[0].store_id

	bad := []rope.Piece {
		{store_id = chunk.Chunk_ID(999), byte_start = 0, byte_length = 1},
		{store_id = valid_id, byte_start = 0, byte_length = 0},
		{store_id = valid_id, byte_start = 0, byte_length = 1000},
		{store_id = valid_id, byte_start = -1, byte_length = 1},
		{store_id = valid_id, byte_start = 6, byte_length = 6}, // overruns len 11
	}
	for p in bad {
		err := rope.append_piece(&s, p)
		testing.expectf(t, err.kind == .Invalid_Input, "piece %v must be rejected", p)
		errs.destroy(&err)
		testing.expect(t, rope.byte_count(&s) == 11, "bad pieces must not change the sequence")
	}

	// A valid subrange piece appends and flattens correctly.
	err := rope.append_piece(&s, rope.Piece{store_id = valid_id, byte_start = 6, byte_length = 3})
	testing.expect(t, errs.ok(err))
	got, rerr := rope.read_all(&s, rope.Byte_Range{0, rope.byte_count(&s)})
	defer delete(got)
	testing.expect(t, errs.ok(rerr))
	testing.expect(t, bytes.equal(got, bytes_of("hello worldwor")), "subrange piece must flatten in place")
}

// test_sequence_arena_lifetime mirrors the product shape: the leaf
// list comes from a growing arena and a single free_all reclaims it
// after destroy (the pool frees its own storage).
@(test)
test_sequence_arena_lifetime :: proc(t: ^testing.T) {
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_growing(&arena) == nil)
	defer mem_virtual.arena_destroy(&arena)
	defer mem_virtual.arena_free_all(&arena)
	alloc := mem_virtual.arena_allocator(&arena)

	store: chunk.Store
	chunk.init(&store, {chunk_size = 16}, alloc)
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {}, alloc)))
	defer rope.sequence_destroy(&s)

	append_text(t, &s, "arena-backed sequence text")
	testing.expect(t, rope.leaf_count(&s) == 1)

	rope.sequence_destroy(&s)
	mem_virtual.arena_free_all(&arena)
	testing.expect(t, arena.total_used == 0, "free_all must reclaim the leaf list")
}

// test_allocation_failure exhausts a fixed buffer arena backing the
// leaf list: growth must fail with .Resource_Limit, the sequence must
// stay consistent, and destroy must remain safe.
@(test)
test_allocation_failure :: proc(t: ^testing.T) {
	buf := make([]byte, 4 * 1024)
	defer delete(buf)
	arena: mem_virtual.Arena
	testing.expect(t, mem_virtual.arena_init_buffer(&arena, buf) == nil)
	defer mem_virtual.arena_destroy(&arena)
	alloc := mem_virtual.arena_allocator(&arena)

	store: chunk.Store
	chunk.init(&store, {chunk_size = 1}, context.allocator)
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {target_leaf_bytes = 1}, alloc)))
	defer rope.sequence_destroy(&s)

	// Each one-byte append opens a new leaf (target 1), growing the
	// leaf list until the fixed arena fails.
	failed := false
	for i in 0 ..< 2000 {
		piece := []byte{u8(i)}
		err := rope.append_data(&s, piece, context.allocator)
		if errs.ok(err) {
			continue
		}
		testing.expect(t, err.kind == .Resource_Limit, "list growth failure must be .Resource_Limit")
		errs.destroy(&err)
		failed = true
		break
	}
	testing.expect(t, failed, "the fixed buffer arena must eventually exhaust")

	// The sequence stays consistent for the content it holds.
	testing.expect(t, rope.byte_count(&s) == rope.piece_count(&s))
	testing.expect(t, rope.byte_count(&s) > 0)
	data := flatten(&s)
	defer delete(data)
	expect_metrics(t, rope.metrics(&s), rope.metrics_of(data), "metrics after failure")

	// A healthy allocator still works for reads.
	got, err := rope.read_all(&s, rope.Byte_Range{0, rope.byte_count(&s)})
	defer delete(got)
	testing.expect(t, errs.ok(err))
}

// flatten returns the whole sequence content with the context
// allocator (caller deletes).
flatten :: proc(s: ^rope.Sequence) -> []byte {
	got, _ := rope.read_all(s, rope.Byte_Range{0, rope.byte_count(s)})
	return got
}

// oracle_metrics counts the content with an independent implementation
// of the same counting policy (a second decoder, different code): the
// differential test compares the sequence's folded metrics against it
// so a bug shared by metrics_of and combine cannot hide.
oracle_metrics :: proc(data: []byte) -> rope.Metrics {
	m := rope.Metrics{byte_count = len(data)}
	j := 0
	for j < len(data) {
		b := data[j]
		if b < 0x80 || b > 0xF4 || (b >= 0x80 && b <= 0xBF) || b == 0xC0 || b == 0xC1 {
			// ASCII, stray continuation, or invalid lead: one scalar.
			m.scalar_count += 1
			j += 1
			continue
		}
		expect := 1
		if b >= 0xE0 && b <= 0xEF {
			expect = 2
		} else if b >= 0xF0 && b <= 0xF4 {
			expect = 3
		}
		n := 0
		for n < expect && j + 1 + n < len(data) && data[j + 1 + n] >= 0x80 && data[j + 1 + n] <= 0xBF {
			n += 1
		}
		// Lead with n continuations (complete, broken, or truncated):
		// one scalar.
		m.scalar_count += 1
		j += 1 + n
	}
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			m.lf_count += 1
		} else if data[i] == '\r' && (i + 1 == len(data) || data[i + 1] != '\n') {
			m.lone_cr_count += 1
		}
	}
	return m
}

// test_randomized_differential is the M02.02 differential property:
// seeded random appends checked against a reference byte model —
// metrics after every append, random range reads (whole, partial
// loop, and spans) along the way, and per-leaf recomputation at the
// end. Chunk size 5 and a tiny leaf target force dense piece and leaf
// boundaries, including multi-byte scalars and CRLF splits.
@(test)
test_randomized_differential :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 5})
	defer chunk.destroy(&store)

	s: rope.Sequence
	testing.expect(t, errs.ok(rope.sequence_init(&s, &store, {target_leaf_bytes = 24})))
	defer rope.sequence_destroy(&s)

	alphabet := bytes_of("ab\r\né€😀z中")
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

	for step in 0 ..< 300 {
		piece := make([]u8, int(next(&state) % 40), context.allocator)
		for &b in piece {
			b = alphabet[int(next(&state) % u64(len(alphabet)))]
		}
		append(&ref, ..piece)

		err := rope.append_data(&s, piece, context.allocator)
		testing.expect(t, errs.ok(err), "append must not fail with a healthy allocator")
		expect_metrics(
			t,
			rope.metrics(&s),
			rope.metrics_of(ref[:]),
			fmt.tprintf("total metrics at step %v", step),
		)

		// Independent oracle: the counting policy re-implemented
		// differently must agree with the folded metrics.
		om := oracle_metrics(ref[:])
		m := rope.metrics(&s)
		testing.expectf(
			t,
			m.byte_count == om.byte_count && m.scalar_count == om.scalar_count &&
			m.lf_count == om.lf_count && m.lone_cr_count == om.lone_cr_count,
			"oracle mismatch at step %v: got %v, want %v",
			step,
			m,
			om,
		)

		if step % 10 == 0 && len(ref) > 0 {
			start := int(next(&state) % u64(len(ref) + 1))
			end := start + int(next(&state) % u64(len(ref) - start + 1))
			range := rope.Byte_Range{start, end}

			whole, rerr := rope.read_all(&s, range)
			testing.expect(t, errs.ok(rerr))
			testing.expectf(t, bytes.equal(whole, ref[:][start:end]), "read_all at step %v", step)
			delete(whole)

			// Partial-read loop with a tiny buffer.
			part := make([dynamic]u8, context.allocator)
			buf: [3]u8
			for pos := start; pos < end; {
				n, perr := rope.read(&s, rope.Byte_Range{pos, end}, buf[:])
				testing.expect(t, errs.ok(perr))
				testing.expect(t, n > 0)
				append(&part, ..buf[:n])
				pos += n
			}
			testing.expect(t, bytes.equal(part[:], ref[:][start:end]))
			delete(part)

			// Span iteration.
			spans := make([dynamic]u8, context.allocator)
			it: rope.Span_Iter
			testing.expect(t, errs.ok(rope.span_iter_init(&it, &s, range)))
			for {
				span, more := rope.span_iter_next(&it, &s)
				if !more {
					break
				}
				append(&spans, ..span)
			}
			testing.expect(t, bytes.equal(spans[:], ref[:][start:end]))
			delete(spans)
		}
		delete(piece, context.allocator)
	}

	// Final: per-leaf invariants and piece-level recomputation.
	for i in 0 ..< rope.leaf_count(&s) {
		leaf := rope.leaf_at(&s, i)
		testing.expect(t, leaf.count >= 1 && leaf.count <= rope.MAX_PIECES_PER_LEAF)
		testing.expectf(t, leaf.metrics.byte_count <= 24, "leaf %v byte bound", i)
		m := rope.Metrics{}
		for j in 0 ..< leaf.count {
			p := leaf.pieces[j]
			d := chunk.data(&store, p.store_id)
			m = rope.combine(m, rope.metrics_of(d[p.byte_start:p.byte_start + p.byte_length]))
		}
		expect_metrics(t, leaf.metrics, m, fmt.tprintf("leaf %v recompute", i))
	}
	expect_metrics(t, rope.metrics(&s), rope.metrics_of(ref[:]), "final total metrics")
	testing.expect(t, rope.byte_count(&s) == len(ref))
}
