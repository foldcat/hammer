// Package filecodec implements the file encoding, BOM, and newline policy
// (M03.03, SPECS.md §7.4) over M03.02's chunked raw loads.
//
// UTF-8 is the only encoding decoded in this slice. A UTF-8 BOM is file
// metadata, not text: `Decoded.content` excludes it while `Decoded.raw`
// retains every original byte. UTF-16/UTF-32 BOMs are recognized and retained
// but open read-only as `.Unsupported_Encoding`; there is no heuristic
// encoding detection for BOM-less input. Invalid UTF-8 is also read-only and
// its bytes are never replaced. M03.04 owns escaped rendering, offset maps,
// and deliberate conversion.
//
// Newline bytes are preserved exactly. The scanner counts lone LF, CRLF, and
// lone CR sequences across arbitrary chunk boundaries; mixed files stay mixed.
// The newline counts describe the BOM-excluding content of UTF-8 and invalid
// UTF-8 inputs. They are unknown for unsupported encodings.
//
// Decoding allocates nothing and does not flatten the input. `raw` and
// `content` are borrowed streams over the `fileload.Loaded` store and id list.
// The Loaded must remain at a fixed location, alive, and unmutated until all
// streams and iterators derived from it are done. `fileload.loaded_destroy`
// invalidates them. A stream iterator yields borrowed immutable chunk spans.
//
// Backend-free and CRT-free: only core/chunk and core/fileload are imported.
package filecodec

import chunk "../chunk"
import fileload "../fileload"

// Encoding is the encoding identified by a Unicode BOM, defaulting to UTF-8
// when no BOM is present. BOM-less UTF-16/32 is not guessed.
Encoding :: enum {
	UTF8,
	UTF16_LE,
	UTF16_BE,
	UTF32_LE,
	UTF32_BE,
}

// BOM records the exact byte-order mark found at the start of the file.
BOM :: enum {
	None,
	UTF8,
	UTF16_LE,
	UTF16_BE,
	UTF32_LE,
	UTF32_BE,
}

// Newline is the content's newline convention. `.Mixed` means more than one
// kind occurs; `.None` means no line breaks; `.Unknown` applies to encodings
// whose raw bytes cannot be scanned as UTF-8/ASCII newline sequences.
Newline :: enum {
	Unknown,
	None,
	LF,
	CRLF,
	CR,
	Mixed,
}

// Newline_Counts counts newline sequences, not individual bytes: `lf` excludes
// the LF in CRLF and `cr` excludes the CR in CRLF.
Newline_Counts :: struct {
	lf:   int,
	crlf: int,
	cr:   int,
}

// Metadata is the original file policy retained for a later save. It is plain
// data and safe to copy. Saving and newline selection for new edits are later
// consumers; opening never rewrites the bytes to this metadata.
Metadata :: struct {
	encoding: Encoding,
	bom:      BOM,
	newline:  Newline,
	newlines: Newline_Counts,
}

// Status controls whether decoded content may enter the editable UTF-8 text
// engine. Invalid and unsupported inputs remain byte-preserving and read-only.
Status :: enum {
	Valid_UTF8,
	Invalid_UTF8,
	Unsupported_Encoding,
}

// Invalid_Reason classifies the first UTF-8 validation failure.
Invalid_Reason :: enum {
	None,
	Unexpected_Continuation,
	Invalid_Continuation,
	Overlong,
	Surrogate,
	Out_Of_Range,
	Truncated,
}

// Invalid_UTF8 locates the first malformed sequence in the original file.
// `raw_offset` includes any UTF-8 BOM. `length` is the malformed prefix length;
// for an invalid non-continuation byte, that offending byte is not included.
Invalid_UTF8 :: struct {
	raw_offset: int,
	length:     int,
	reason:     Invalid_Reason,
}

// Byte_Stream is a borrowed, contiguous logical byte range over ordered chunks.
// `raw_start` is relative to the start of the complete id list, not a chunk.
Byte_Stream :: struct {
	store:     ^chunk.Store,
	ids:       []chunk.Chunk_ID,
	raw_start: int,
	length:    int,
}

// Decoded is the non-owning result of inspecting a Loaded. `raw` always
// reproduces the complete file. `content` excludes a UTF-8 BOM for valid or
// invalid UTF-8; it is empty for unsupported encodings. Content is guaranteed
// valid UTF-8 only when status is `.Valid_UTF8`.
Decoded :: struct {
	metadata: Metadata,
	status:   Status,
	invalid:  Invalid_UTF8,
	raw:      Byte_Stream,
	content:  Byte_Stream,
}

// Span_Iter walks a Byte_Stream without allocating. Spans are borrowed from
// immutable chunks and remain valid under the Byte_Stream lifetime contract.
Span_Iter :: struct {
	stream:    Byte_Stream,
	index:     int,
	skip:      int,
	remaining: int,
}

// utf8_scanner carries a possibly split sequence across chunk boundaries.
utf8_scanner :: struct {
	remaining:  u8,
	next_lo:    u8,
	next_hi:    u8,
	start:      int,
	constraint: Invalid_Reason,
	invalid:    Invalid_UTF8,
	failed:     bool,
}

// newline_scanner carries a trailing CR until the next byte resolves it.
newline_scanner :: struct {
	counts:    Newline_Counts,
	pending_cr: bool,
}

// can_edit reports whether content is valid UTF-8 and may enter the editable
// internal text model. No status performs an implicit conversion.
can_edit :: proc(decoded: Decoded) -> bool {
	return decoded.status == .Valid_UTF8
}

// stream_iter_init prepares an allocation-free iterator over stream.
stream_iter_init :: proc(stream: Byte_Stream) -> Span_Iter {
	it := Span_Iter{stream = stream, remaining = stream.length}
	if it.remaining <= 0 {
		return it
	}
	start := stream.raw_start
	for it.index < len(stream.ids) {
		data_len := len(chunk.data(stream.store, stream.ids[it.index]))
		if start < data_len {
			it.skip = start
			break
		}
		start -= data_len
		it.index += 1
	}
	return it
}

// stream_iter_next returns the next borrowed span, or ok=false at the end.
stream_iter_next :: proc(it: ^Span_Iter) -> (span: []byte, ok: bool) {
	if it.remaining <= 0 || it.index >= len(it.stream.ids) {
		return {}, false
	}
	data := chunk.data(it.stream.store, it.stream.ids[it.index])
	available := len(data) - it.skip
	n := min(available, it.remaining)
	span = data[it.skip:it.skip + n]
	it.index += 1
	it.skip = 0
	it.remaining -= n
	return span, true
}

// decode_loaded inspects raw chunked file content without changing or copying
// it. The returned streams borrow `loaded`; see the package lifetime contract.
decode_loaded :: proc(loaded: ^fileload.Loaded) -> Decoded {
	total := 0
	for id in loaded.ids {
		total += len(chunk.data(&loaded.store, id))
	}
	decoded := Decoded {
		raw = Byte_Stream {
			store = &loaded.store,
			ids = loaded.ids[:],
			raw_start = 0,
			length = total,
		},
	}

	prefix: [4]u8
	prefix_len := 0
	raw_it := stream_iter_init(decoded.raw)
	for prefix_len < len(prefix) {
		span, ok := stream_iter_next(&raw_it)
		if !ok {
			break
		}
		n := min(len(span), len(prefix) - prefix_len)
		copy(prefix[prefix_len:], span[:n])
		prefix_len += n
	}

	bom_len := detect_bom(prefix[:prefix_len], &decoded.metadata)
	if decoded.metadata.encoding != .UTF8 {
		decoded.status = .Unsupported_Encoding
		decoded.metadata.newline = .Unknown
		decoded.content = Byte_Stream {
			store = &loaded.store,
			ids = loaded.ids[:],
			raw_start = total,
			length = 0,
		}
		return decoded
	}

	decoded.content = Byte_Stream {
		store = &loaded.store,
		ids = loaded.ids[:],
		raw_start = bom_len,
		length = total - bom_len,
	}
	newlines: newline_scanner
	utf8s := utf8_scanner{next_lo = 0x80, next_hi = 0xbf}
	content_it := stream_iter_init(decoded.content)
	for {
		span, ok := stream_iter_next(&content_it)
		if !ok {
			break
		}
		span_raw_start := decoded.content.length - content_it.remaining - len(span) + bom_len
		for b, index in span {
			offset := span_raw_start + index
			newline_feed(&newlines, b)
			utf8_feed(&utf8s, b, offset)
		}
	}
	newline_finish(&newlines)
	utf8_finish(&utf8s, total)
	decoded.metadata.newlines = newlines.counts
	decoded.metadata.newline = newline_style(newlines.counts)
	if utf8s.failed {
		decoded.status = .Invalid_UTF8
		decoded.invalid = utf8s.invalid
	} else {
		decoded.status = .Valid_UTF8
	}
	return decoded
}

// detect_bom recognizes the longest Unicode BOM first: UTF-32 LE shares the
// two-byte UTF-16 LE prefix. It returns the number of metadata-only bytes.
detect_bom :: proc(prefix: []byte, metadata: ^Metadata) -> int {
	if len(prefix) >= 4 {
		if prefix[0] == 0xff && prefix[1] == 0xfe && prefix[2] == 0x00 && prefix[3] == 0x00 {
			metadata.encoding = .UTF32_LE
			metadata.bom = .UTF32_LE
			return 4
		}
		if prefix[0] == 0x00 && prefix[1] == 0x00 && prefix[2] == 0xfe && prefix[3] == 0xff {
			metadata.encoding = .UTF32_BE
			metadata.bom = .UTF32_BE
			return 4
		}
	}
	if len(prefix) >= 3 && prefix[0] == 0xef && prefix[1] == 0xbb && prefix[2] == 0xbf {
		metadata.encoding = .UTF8
		metadata.bom = .UTF8
		return 3
	}
	if len(prefix) >= 2 {
		if prefix[0] == 0xff && prefix[1] == 0xfe {
			metadata.encoding = .UTF16_LE
			metadata.bom = .UTF16_LE
			return 2
		}
		if prefix[0] == 0xfe && prefix[1] == 0xff {
			metadata.encoding = .UTF16_BE
			metadata.bom = .UTF16_BE
			return 2
		}
	}
	metadata.encoding = .UTF8
	metadata.bom = .None
	return 0
}

// utf8_feed accepts one byte at raw_offset. Only the first error is retained;
// newline scanning continues independently to the end of the input.
utf8_feed :: proc(s: ^utf8_scanner, b: u8, raw_offset: int) {
	if s.failed {
		return
	}
	if s.remaining > 0 {
		if b < s.next_lo || b > s.next_hi {
			reason := Invalid_Reason.Invalid_Continuation
			length := raw_offset - s.start
			if b >= 0x80 && b <= 0xbf {
				if s.constraint != .None {
					reason = s.constraint
				}
				length += 1
			}
			utf8_fail(s, s.start, length, reason)
			return
		}
		s.remaining -= 1
		s.next_lo = 0x80
		s.next_hi = 0xbf
		s.constraint = .None
		return
	}

	if b <= 0x7f {
		return
	}
	if b >= 0x80 && b <= 0xbf {
		utf8_fail(s, raw_offset, 1, .Unexpected_Continuation)
		return
	}
	if b == 0xc0 || b == 0xc1 {
		utf8_fail(s, raw_offset, 1, .Overlong)
		return
	}
	if b >= 0xf5 {
		utf8_fail(s, raw_offset, 1, .Out_Of_Range)
		return
	}

	s.start = raw_offset
	s.next_lo = 0x80
	s.next_hi = 0xbf
	switch {
	case b >= 0xc2 && b <= 0xdf:
		s.remaining = 1
	case b == 0xe0:
		s.remaining = 2
		s.next_lo = 0xa0
		s.constraint = .Overlong
	case b >= 0xe1 && b <= 0xec:
		s.remaining = 2
	case b == 0xed:
		s.remaining = 2
		s.next_hi = 0x9f
		s.constraint = .Surrogate
	case b >= 0xee && b <= 0xef:
		s.remaining = 2
	case b == 0xf0:
		s.remaining = 3
		s.next_lo = 0x90
		s.constraint = .Overlong
	case b >= 0xf1 && b <= 0xf3:
		s.remaining = 3
	case b == 0xf4:
		s.remaining = 3
		s.next_hi = 0x8f
		s.constraint = .Out_Of_Range
	}
}

utf8_finish :: proc(s: ^utf8_scanner, total: int) {
	if !s.failed && s.remaining > 0 {
		utf8_fail(s, s.start, total - s.start, .Truncated)
	}
}

utf8_fail :: proc(s: ^utf8_scanner, raw_offset, length: int, reason: Invalid_Reason) {
	s.failed = true
	s.invalid = Invalid_UTF8{raw_offset = raw_offset, length = length, reason = reason}
}

newline_feed :: proc(s: ^newline_scanner, b: u8) {
	if s.pending_cr {
		if b == '\n' {
			s.counts.crlf += 1
			s.pending_cr = false
			return
		}
		s.counts.cr += 1
		s.pending_cr = false
	}
	if b == '\r' {
		s.pending_cr = true
	} else if b == '\n' {
		s.counts.lf += 1
	}
}

newline_finish :: proc(s: ^newline_scanner) {
	if s.pending_cr {
		s.counts.cr += 1
		s.pending_cr = false
	}
}

newline_style :: proc(counts: Newline_Counts) -> Newline {
	kinds := 0
	if counts.lf > 0 {
		kinds += 1
	}
	if counts.crlf > 0 {
		kinds += 1
	}
	if counts.cr > 0 {
		kinds += 1
	}
	if kinds == 0 {
		return .None
	}
	if kinds > 1 {
		return .Mixed
	}
	if counts.lf > 0 {
		return .LF
	}
	if counts.crlf > 0 {
		return .CRLF
	}
	return .CR
}
