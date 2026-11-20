// Package console implements streaming decoding of process terminal output for
// the Unicode ANSI console (M10). It is backend-free and CRT-free: it imports
// nothing from the platform layer and performs no allocation. This file is the
// chunk-safe UTF-8 decoder (M10.01); the ANSI state machine and styled log
// rendering (M10.02+) build on the rune stream it produces.
//
// Process output arrives in arbitrary chunks (docs/notes/m00-07-pty.md,
// Finding 3), so a multi-byte UTF-8 sequence may be split across two chunks.
// The Decoder carries any incomplete sequence into the next call and never
// requires the caller to align chunks to rune boundaries.
//
// Invalid bytes are replaced deterministically with U+FFFD using the Unicode
// "maximal subpart" rule (Conformance clause C10): the longest well-formed
// prefix of an ill-formed sequence is replaced by exactly one U+FFFD, so the
// decoded output does not depend on where chunks happen to split.
package console

// REPLACEMENT is U+FFFD, emitted for every ill-formed UTF-8 subsequence.
REPLACEMENT :: '\ufffd'

// Decoder converts a UTF-8 byte stream into Unicode scalar values across
// arbitrary chunk boundaries. It is a fixed-location, allocation-free value:
// keep it at one address and do not copy it while it carries an incomplete
// sequence. The zero value is an idle decoder ready for input.
Decoder :: struct {
	// pending holds the bytes of the sequence currently being carried
	// across chunk boundaries. pending[0] is the leading byte; the rest
	// are continuation bytes. Only pending[:pending_len] is meaningful.
	pending: [4]u8,
	// pending_len is the number of carried bytes; 0 means the decoder is
	// idle (between sequences).
	pending_len: u8,
	// want is the total byte length of the carried sequence (2, 3, or 4);
	// it is 0 while idle.
	want: u8,
	// first_lo/first_hi is the allowed range for the first continuation
	// byte of the carried sequence (the lead byte constrains it to reject
	// overlong, surrogate, and out-of-range encodings). Later continuations
	// are always 0x80..=0xbf.
	first_lo: u8,
	first_hi: u8,
	// replacements counts emitted U+FFFD values for diagnostics.
	replacements: u64,
}

// decode consumes input, appending decoded Unicode scalar values to out. It
// returns the number of scalars written and the number of input bytes
// consumed. If out fills before input is exhausted, consumed is less than
// len(input); resume by calling decode again with the remaining input and a
// fresh out buffer. A buffer of len(input)+1 runes always consumes all of
// input. d must be non-nil and out must be non-empty to make progress.
decode :: proc(d: ^Decoder, input: []byte, out: []rune) -> (written: int, consumed: int) {
	i := 0
	n := len(input)
	for i < n && written < len(out) {
		b := input[i]
		if d.pending_len > 0 {
			lo, hi := d.first_lo, d.first_hi
			if d.pending_len > 1 {
				lo, hi = 0x80, 0xbf
			}
			if b < lo || b > hi {
				// b is not a valid continuation here: replace the carried
				// maximal subpart with one U+FFFD and reprocess b fresh
				// without consuming it.
				out[written] = REPLACEMENT
				written += 1
				d.replacements += 1
				d.pending_len = 0
				d.want = 0
				continue
			}
			d.pending[int(d.pending_len)] = b
			d.pending_len += 1
			i += 1
			if d.pending_len == d.want {
				out[written] = combine(d.pending[:int(d.want)])
				written += 1
				d.pending_len = 0
				d.want = 0
			}
			continue
		}
		if b <= 0x7f {
			out[written] = rune(b)
			written += 1
			i += 1
			continue
		}
		if !start_sequence(d, b) {
			out[written] = REPLACEMENT
			written += 1
			d.replacements += 1
		}
		i += 1
	}
	return written, i
}

// finish flushes end-of-stream state. If an incomplete sequence is pending,
// it is replaced by exactly one U+FFFD and finish returns (REPLACEMENT, true);
// otherwise it returns (0, false). After finish the decoder is idle and may be
// reused for a new stream.
finish :: proc(d: ^Decoder) -> (replacement: rune, truncated: bool) {
	if d.pending_len == 0 {
		return 0, false
	}
	d.pending_len = 0
	d.want = 0
	d.replacements += 1
	return REPLACEMENT, true
}

// start_sequence classifies a non-ASCII leading byte b and, when it begins a
// valid multi-byte sequence, records the pending lead and the continuation
// constraints, returning true. It returns false for bytes that can never begin
// a valid sequence (isolated continuations, overlong C0/C1, and out-of-range
// F5..=FF), which the caller replaces with U+FFFD.
start_sequence :: proc(d: ^Decoder, b: u8) -> bool {
	want: u8
	lo: u8 = 0x80
	hi: u8 = 0xbf
	switch {
	case b <= 0xc1:
		return false
	case b <= 0xdf:
		want = 2
	case b == 0xe0:
		want = 3
		lo = 0xa0
	case b <= 0xec:
		want = 3
	case b == 0xed:
		want = 3
		hi = 0x9f
	case b <= 0xef:
		want = 3
	case b == 0xf0:
		want = 4
		lo = 0x90
	case b <= 0xf3:
		want = 4
	case b == 0xf4:
		want = 4
		hi = 0x8f
	case:
		return false
	}
	d.pending[0] = b
	d.pending_len = 1
	d.want = want
	d.first_lo = lo
	d.first_hi = hi
	return true
}

// combine assembles a scalar value from a validated 2..=4 byte sequence.
// Continuation ranges have already been enforced, so the payload bits are
// combined directly.
combine :: proc(seq: []u8) -> rune {
	switch len(seq) {
	case 2:
		return (rune(seq[0] & 0x1f) << 6) | rune(seq[1] & 0x3f)
	case 3:
		return (rune(seq[0] & 0x0f) << 12) | (rune(seq[1] & 0x3f) << 6) | rune(seq[2] & 0x3f)
	case 4:
		return (rune(seq[0] & 0x07) << 18) | (rune(seq[1] & 0x3f) << 12) | (rune(seq[2] & 0x3f) << 6) | rune(seq[3] & 0x3f)
	}
	return REPLACEMENT
}
