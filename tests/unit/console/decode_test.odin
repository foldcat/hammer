// Tests for M10.01: the chunk-safe UTF-8 decoder. Valid inputs are compared
// against the pinned standard library; invalid inputs are checked against the
// Unicode "maximal subpart" replacement table; chunk-boundary invariance is
// checked by feeding deterministic pseudo-random byte streams whole and in
// random splits.
package console_test

import "core:testing"
import "core:unicode/utf8"

import console "hammer:core/console"

// decode_with_chunk_size feeds data to a fresh decoder in chunk_size chunks and
// returns every decoded rune (including any end-of-stream replacement). Callers
// own the returned dynamic array. chunk_size must be at least 1.
decode_with_chunk_size :: proc(data: []byte, chunk_size: int) -> [dynamic]rune {
	out := make([dynamic]rune, context.allocator)
	d: console.Decoder
	buf := make([]rune, chunk_size + 1, context.allocator)
	defer delete(buf)
	for offset := 0; offset < len(data); offset += chunk_size {
		end := min(offset + chunk_size, len(data))
		written, _ := console.decode(&d, data[offset:end], buf)
		append(&out, ..buf[:written])
	}
	if r, ok := console.finish(&d); ok {
		append(&out, r)
	}
	return out
}

// reference_runes returns the scalar values of a valid UTF-8 byte string.
reference_runes :: proc(data: []byte) -> [dynamic]rune {
	out := make([dynamic]rune, context.allocator)
	for r in string(data) {
		append(&out, r)
	}
	return out
}

expect_runes_equal :: proc(t: ^testing.T, got, want: []rune) {
	testing.expectf(
		t,
		len(got) == len(want),
		"rune count mismatch: got %d want %d (got %v)",
		len(got),
		len(want),
		got,
	)
	n := min(len(got), len(want))
	for i in 0 ..< n {
		testing.expectf(t, got[i] == want[i], "rune %d mismatch: got %x want %x", i, got[i], want[i])
	}
}

@(test)
test_decode_ascii_passthrough :: proc(t: ^testing.T) {
	data := transmute([]byte)string("hello, world!\n\t\r\x00\x7f")
	for chunk_size := 1; chunk_size <= len(data); chunk_size += 1 {
		got := decode_with_chunk_size(data, chunk_size)
		defer delete(got)
		want := reference_runes(data)
		defer delete(want)
		expect_runes_equal(t, got[:], want[:])
		testing.expect(t, len(got) == len(data))
	}
}

@(test)
test_decode_scalar_boundaries_at_every_split :: proc(t: ^testing.T) {
	cases := []struct {
		data: string,
		want: rune,
	}{
		{data = "\x00", want = 0x00},
		{data = "\x7f", want = 0x7f},
		{data = "\xc2\x80", want = 0x80},
		{data = "\xdf\xbf", want = 0x7ff},
		{data = "\xe0\xa0\x80", want = 0x800},
		{data = "\xed\x9f\xbf", want = 0xd7ff},
		{data = "\xee\x80\x80", want = 0xe000},
		{data = "\xef\xbf\xbf", want = 0xffff},
		{data = "\xf0\x90\x80\x80", want = 0x10000},
		{data = "\xf4\x8f\xbf\xbf", want = 0x10ffff},
	}
	for c in cases {
		bytes := transmute([]byte)c.data
		for chunk_size := 1; chunk_size <= len(bytes); chunk_size += 1 {
			got := decode_with_chunk_size(bytes, chunk_size)
			testing.expectf(
				t,
				len(got) == 1,
				"expected one scalar for %v at chunk size %d, got %v",
				bytes,
				chunk_size,
				got[:],
			)
			if len(got) == 1 {
				testing.expectf(t, got[0] == c.want, "wrong scalar for %v: got %x want %x", bytes, got[0], c.want)
			}
			delete(got)
		}
	}
}

@(test)
test_decode_valid_utf8_matches_reference :: proc(t: ^testing.T) {
	cases := []string{
		"",
		"plain ascii",
		"α β γ δ",
		"你好，世界",
		"🌍 emoji 🎉 mixed élan",
		"a\u00e9b\u00e8c\u00ea", // combining and precomposed latin
		"\u0800\u0801\ufffd\u10000\u10ffff",
	}
	for data in cases {
		bytes := transmute([]byte)data
		want := reference_runes(bytes)
		defer delete(want)
		testing.expect(t, utf8.valid_string(data))
		for chunk_size := 1; chunk_size <= max(len(bytes), 1); chunk_size += 1 {
			got := decode_with_chunk_size(bytes, chunk_size)
			expect_runes_equal(t, got[:], want[:])
			delete(got)
		}
	}
}

@(test)
test_decode_invalid_maximal_subpart_replacement :: proc(t: ^testing.T) {
	// Each case asserts the exact rune stream for an ill-formed byte
	// sequence, per Unicode Conformance clause C10 (one U+FFFD per maximal
	// subpart). The trailing replacement for truncated sequences is emitted
	// by finish().
	cases := []struct {
		data: string,
		want: []rune,
	}{
		{data = "\x80", want = []rune{console.REPLACEMENT}},
		{data = "\xbf", want = []rune{console.REPLACEMENT}},
		{data = "\xc0\xaf", want = []rune{console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xc1\xbf", want = []rune{console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xe0\x80\xaf", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xe0\x9f\xbf", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xed\xa0\x80", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xf0\x80\x80\x80", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xf0\x8f\xbf\xbf", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xf4\x90\x80\x80", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xf5\x80\x80\x80", want = []rune{console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT, console.REPLACEMENT}},
		{data = "\xff", want = []rune{console.REPLACEMENT}},
		{data = "\xc2A", want = []rune{console.REPLACEMENT, 'A'}},
		{data = "\xe1\x80A", want = []rune{console.REPLACEMENT, 'A'}},
		{data = "\xf1\x80\x80A", want = []rune{console.REPLACEMENT, 'A'}},
		{data = "\xc2", want = []rune{console.REPLACEMENT}},
		{data = "\xe1\x80", want = []rune{console.REPLACEMENT}},
		{data = "\xf1\x80\x80", want = []rune{console.REPLACEMENT}},
	}
	for c in cases {
		bytes := transmute([]byte)c.data
		for chunk_size := 1; chunk_size <= max(len(bytes), 1); chunk_size += 1 {
			got := decode_with_chunk_size(bytes, chunk_size)
			expect_runes_equal(t, got[:], c.want)
			delete(got)
		}
	}
}

@(test)
test_decode_replacement_count :: proc(t: ^testing.T) {
	// \x80 → one replacement, \xe1\x80A → one replacement plus 'A', and
	// \xf4\x90 → two replacements: F4 is rejected because its first
	// continuation must be in 0x80..=0x8f, and the isolated 0x90 is then an
	// unexpected continuation on its own.
	data := transmute([]byte)string("\x80ok\xe1\x80A\xf4\x90")
	d: console.Decoder
	buf := make([]rune, len(data) + 1, context.allocator)
	defer delete(buf)
	written, consumed := console.decode(&d, data, buf)
	testing.expect(t, consumed == len(data))
	testing.expect(t, written == 7)
	_, truncated := console.finish(&d)
	testing.expect(t, !truncated)
	testing.expect(t, d.replacements == 4)
}

@(test)
test_decode_chunk_boundary_invariance :: proc(t: ^testing.T) {
	state := u64(0x9e3779b97f4a7c15)
	for _ in 0 ..< 2000 {
		state = xorshift64(state)
		n := int(state % 64)
		data := make([]byte, n, context.allocator)
		for i in 0 ..< n {
			state = xorshift64(state)
			data[i] = u8(state >> 32)
		}
		whole := decode_with_chunk_size(data, max(n, 1))
		single := decode_with_chunk_size(data, 1)

		// A random split: decode the first half at size 1 and the second
		// half at a random larger size, via a shared decoder.
		d: console.Decoder
		split := make([dynamic]rune, context.allocator)
		buf := make([]rune, 17, context.allocator)
		mid := int(state % u64(max(n, 1)))
		state = xorshift64(state)
		second := int(1 + state % 13)
		offset := 0
		chunks := [2]int{max(mid, 1), second}
		for chunk in chunks {
			end := min(offset + chunk, n)
			for offset < end {
				written, consumed := console.decode(&d, data[offset:end], buf)
				append(&split, ..buf[:written])
				offset += consumed
			}
		}
		for offset < n {
			written, consumed := console.decode(&d, data[offset:], buf)
			append(&split, ..buf[:written])
			offset += consumed
		}
		if r, ok := console.finish(&d); ok {
			append(&split, r)
		}

		expect_runes_equal(t, single[:], whole[:])
		expect_runes_equal(t, split[:], whole[:])
		delete(split)
		delete(buf)
		delete(single)
		delete(whole)
		delete(data)
	}
}

@(test)
test_decode_partial_consumption_reassembles :: proc(t: ^testing.T) {
	data := transmute([]byte)string("héllo wörld ✓ 你好 🌍 mixed")
	whole := decode_with_chunk_size(data, len(data))
	defer delete(whole)

	d: console.Decoder
	out := make([dynamic]rune, context.allocator)
	defer delete(out)
	buf := make([]rune, 2, context.allocator)
	defer delete(buf)
	remaining := data
	guard := 0
	for len(remaining) > 0 && guard < 100000 {
		written, consumed := console.decode(&d, remaining, buf)
		testing.expect(t, written > 0 || consumed > 0)
		append(&out, ..buf[:written])
		remaining = remaining[consumed:]
		guard += 1
	}
	testing.expect(t, len(remaining) == 0)
	if r, ok := console.finish(&d); ok {
		append(&out, r)
	}
	expect_runes_equal(t, out[:], whole[:])
}

@(test)
test_finish_behavior :: proc(t: ^testing.T) {
	d: console.Decoder
	replacement, truncated := console.finish(&d)
	testing.expect(t, !truncated)
	testing.expect(t, replacement == 0)

	buf := make([]rune, 4, context.allocator)
	defer delete(buf)
	written, consumed := console.decode(&d, transmute([]byte)string("\xf0\x9f"), buf)
	testing.expect(t, consumed == 2)
	testing.expect(t, written == 0)
	replacement, truncated = console.finish(&d)
	testing.expect(t, truncated)
	testing.expect(t, replacement == console.REPLACEMENT)
	// Finish is idempotent after the flush.
	replacement, truncated = console.finish(&d)
	testing.expect(t, !truncated)
	testing.expect(t, d.replacements == 1)
}

xorshift64 :: proc(x: u64) -> u64 {
	x := x
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	return x
}
