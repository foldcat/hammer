// Streaming terminal-emulation integration (M10.06).
//
// This file composes the M10.01-M10.04 primitives — the chunk-safe UTF-8
// decoder (`decode.odin`), the ANSI state machine (`ansi.odin`), and the
// line-oriented progress buffer (`line.odin`) — into one stateful Stream that
// turns raw process output bytes into clean UTF-8 text. Escape sequences are
// consumed deterministically (never echoed), CR/backspace/erase edits collapse
// in-place progress, and each completed line is emitted with its trailing
// newline restored. This is the log-window half of SPECS §12.5 (model A); the
// terminal grid (model B) is M10.07.
//
// Style runs and hyperlinks are computed by the underlying Line_Buffer but not
// rendered here: the caller receives plain text bytes, so the output window
// stays readable and selectable. Per-run color rendering and style storage are
// a later milestone (SPECS §12.7).
//
// A Stream is a fixed-location value. Keep it at one address and do not copy
// it while it holds a partial line or escape sequence. Output is appended to a
// caller-owned dynamic byte buffer; the stream's scratch buffers are allocated
// once at init and reused, so the data path performs no allocation beyond the
// transient Line values it frees immediately.
package console

import "base:runtime"

import errs "../errs"

// STREAM_RUNE_BUF and STREAM_EVENT_BUF size the scratch buffers that convert
// bytes to runes and runes to parser events. The stream loops, so input larger
// than these is processed in bounded pieces. STREAM_EVENT_BUF must be at least
// STREAM_RUNE_BUF so feed always consumes a full rune batch in one call.
STREAM_RUNE_BUF :: 512
STREAM_EVENT_BUF :: 512

// Stream composes the decoder, ANSI parser, and line buffer into a single
// chunk-safe byte-to-text converter.
Stream :: struct {
	allocator: runtime.Allocator,
	decoder:   Decoder,
	parser:    Parser,
	line:      Line_Buffer,
	lines:     [dynamic]Line,  // transient completed-line scratch
	runes:     [dynamic]rune,  // decode scratch
	events:    [dynamic]Event, // parser scratch
}

// stream_init prepares s. Completed lines and scratch buffers are allocated
// with allocator.
stream_init :: proc(s: ^Stream, allocator := context.allocator) -> errs.Error {
	if s == nil {
		return errs.new(.Invalid_Input, "console: stream is nil", allocator = allocator)
	}
	s^ = {allocator = allocator}
	if err := parser_init(&s.parser, allocator); !errs.ok(err) {
		s^ = {}
		return err
	}
	if err := line_buffer_init(&s.line, 0, allocator); !errs.ok(err) {
		parser_destroy(&s.parser)
		s^ = {}
		return err
	}
	s.lines = make([dynamic]Line, allocator)
	s.runes = make([dynamic]rune, allocator)
	resize(&s.runes, STREAM_RUNE_BUF)
	s.events = make([dynamic]Event, allocator)
	resize(&s.events, STREAM_EVENT_BUF)
	return {}
}

// stream_destroy releases the stream's storage. It does not free any bytes
// already appended to the caller's output buffer.
stream_destroy :: proc(s: ^Stream) {
	if s == nil {
		return
	}
	for line in s.lines {
		line_destroy(line, s.allocator)
	}
	delete(s.lines)
	delete(s.runes)
	delete(s.events)
	line_buffer_destroy(&s.line)
	parser_destroy(&s.parser)
	s^ = {}
}

// stream_feed consumes raw output bytes and appends decoded clean text to out.
// Completed lines are emitted as they terminate (each followed by a '\n'); a
// partial trailing line stays in the stream until stream_flush. Escape
// sequences are consumed deterministically. The call consumes all of input.
stream_feed :: proc(s: ^Stream, input: []byte, out: ^[dynamic]byte) -> errs.Error {
	if s == nil || s.allocator.procedure == nil {
		return errs.new(.Invalid_Input, "console: stream is not initialized")
	}
	remaining := input
	for len(remaining) > 0 {
		written, consumed := decode(&s.decoder, remaining, s.runes[:])
		if consumed == 0 && written == 0 {
			return errs.new(.Internal, "console: decoder made no progress")
		}
		stream_feed_runes(s, s.runes[:written], out)
		remaining = remaining[consumed:]
	}
	return {}
}

// stream_flush emits trailing state at end-of-stream: a truncated UTF-8
// sequence becomes one U+FFFD, and a trailing partial line is emitted.
// It is idempotent; calling it twice emits nothing the second time.
stream_flush :: proc(s: ^Stream, out: ^[dynamic]byte) -> errs.Error {
	if s == nil || s.allocator.procedure == nil {
		return errs.new(.Invalid_Input, "console: stream is not initialized")
	}
	if replacement, truncated := finish(&s.decoder); truncated {
		s.runes[0] = replacement
		stream_feed_runes(s, s.runes[:1], out)
	}
	line_buffer_flush(&s.line, &s.lines)
	stream_drain_lines(s, out)
	return {}
}

// stream_feed_runes feeds decoded runes through the ANSI parser and line
// buffer, draining any completed lines into out.
stream_feed_runes :: proc(s: ^Stream, runes: []rune, out: ^[dynamic]byte) {
	// STREAM_EVENT_BUF >= STREAM_RUNE_BUF, so feed consumes every rune in a
	// single call (its documented contract: len(input) events consume all).
	remaining := runes
	for len(remaining) > 0 {
		written, consumed := feed(&s.parser, remaining, s.events[:])
		line_buffer_feed(&s.line, s.events[:written], &s.lines, nil)
		stream_drain_lines(s, out)
		remaining = remaining[consumed:]
	}
}

// stream_drain_lines encodes and frees every completed line in s.lines.
stream_drain_lines :: proc(s: ^Stream, out: ^[dynamic]byte) {
	for line in s.lines {
		append_line_bytes(out, line)
		line_destroy(line, s.allocator)
	}
	resize(&s.lines, 0)
}

// append_line_bytes appends a completed line's text followed by a newline.
append_line_bytes :: proc(out: ^[dynamic]byte, line: Line) {
	for r in line.text {
		buffer: [4]byte
		n := encode_utf8(r, buffer[:])
		append(out, ..buffer[:n])
	}
	append(out, '\n')
}

// encode_utf8 writes the UTF-8 encoding of a valid scalar value r into out and
// returns the number of bytes written (1..4).
encode_utf8 :: proc(r: rune, out: []byte) -> int {
	switch {
	case r <= 0x7f:
		out[0] = u8(r)
		return 1
	case r <= 0x7ff:
		out[0] = u8(0xc0 | (r >> 6))
		out[1] = u8(0x80 | (r & 0x3f))
		return 2
	case r <= 0xffff:
		out[0] = u8(0xe0 | (r >> 12))
		out[1] = u8(0x80 | ((r >> 6) & 0x3f))
		out[2] = u8(0x80 | (r & 0x3f))
		return 3
	case:
		out[0] = u8(0xf0 | (r >> 18))
		out[1] = u8(0x80 | ((r >> 12) & 0x3f))
		out[2] = u8(0x80 | ((r >> 6) & 0x3f))
		out[3] = u8(0x80 | (r & 0x3f))
		return 4
	}
}
