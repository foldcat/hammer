// Tests for M10.06: the composed streaming terminal-emulation layer. Each
// byte sequence is decoded, ANSI-parsed, and line-buffered through one Stream,
// producing clean UTF-8 text with escape sequences consumed and CR/backspace/
// erase progress collapsed.
package console_test

import "core:testing"

import console "hammer:core/console"

// stream_output feeds data through a fresh stream at the given chunk size and
// returns the accumulated clean text. The caller owns the returned buffer.
stream_output :: proc(data: []byte, chunk: int, flush := true) -> [dynamic]byte {
	stream: console.Stream
	console.stream_init(&stream, context.allocator)
	defer console.stream_destroy(&stream)
	out := make([dynamic]byte, context.allocator)
	remaining := data
	for len(remaining) > 0 {
		count := min(chunk, len(remaining))
		console.stream_feed(&stream, remaining[:count], &out)
		remaining = remaining[count:]
	}
	if flush {
		console.stream_flush(&stream, &out)
	}
	return out
}

expect_stream :: proc(t: ^testing.T, data: []byte, chunk: int, want: string) {
	out := stream_output(data, chunk)
	defer delete(out)
	testing.expectf(t, string(out[:]) == want, "got %q, want %q", string(out[:]), want)
}

@(test)
test_stream_plain_text_passthrough :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("hello\nworld\n"), 1, "hello\nworld\n")
}

@(test)
test_stream_strips_ansi_styles :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("\x1b[31mRED\x1b[0m\n"), 1, "RED\n")
	expect_stream(t, transmute([]byte)string("a\x1b[31mb\x1b[0mc\n"), 1, "abc\n")
	expect_stream(t, transmute([]byte)string("\x1b[38;5;208mx\x1b[0m\n"), 1, "x\n")
}

@(test)
test_stream_carriage_return_progress :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("foo\rbar\n"), 1, "bar\n")
	expect_stream(t, transmute([]byte)string("hello\rhi\n"), 1, "hillo\n")
}

@(test)
test_stream_backspace_and_erase :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("ab\bcd\n"), 1, "acd\n")
	expect_stream(t, transmute([]byte)string("hello\r\x1b[Kworld\n"), 1, "world\n")
	expect_stream(t, transmute([]byte)string("hello\x1b[2Kworld\n"), 1, "world\n")
}

@(test)
test_stream_consumes_hyperlink_osc :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("\x1b]8;;http://a\x1b\\x\x1b]8;;\x1b\\\n"), 1, "x\n")
}

@(test)
test_stream_holds_partial_line_until_flush :: proc(t: ^testing.T) {
	stream: console.Stream
	console.stream_init(&stream, context.allocator)
	defer console.stream_destroy(&stream)
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.stream_feed(&stream, transmute([]byte)string("hello"), &out)
	testing.expect(t, len(out) == 0)
	console.stream_flush(&stream, &out)
	testing.expectf(t, string(out[:]) == "hello\n", "got %q", string(out[:]))
	// flush is idempotent
	console.stream_flush(&stream, &out)
	testing.expect(t, string(out[:]) == "hello\n")
}

@(test)
test_stream_truncated_utf8_becomes_replacement :: proc(t: ^testing.T) {
	stream: console.Stream
	console.stream_init(&stream, context.allocator)
	defer console.stream_destroy(&stream)
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.stream_feed(&stream, transmute([]byte)string("\xe2\x82"), &out)
	testing.expect(t, len(out) == 0)
	console.stream_flush(&stream, &out)
	testing.expectf(t, string(out[:]) == "\ufffd\n", "got %q", string(out[:]))
}

@(test)
test_stream_multibyte_utf8_passthrough :: proc(t: ^testing.T) {
	expect_stream(t, transmute([]byte)string("caf\u00e9\n"), 1, "caf\u00e9\n")
	expect_stream(t, transmute([]byte)string("\u0800\U0001f600\n"), 2, "\u0800\U0001f600\n")
}

@(test)
test_stream_chunk_boundary_invariance :: proc(t: ^testing.T) {
	inputs := []string {
		"\x1b[31mred\x1b[0m green\nprogress\rfinal\n",
		"caf\u00e9 \u00e9t\u00e9\n\x1b[2Kdone\n",
		"\x1b]8;;http://a\x1b\\link\x1b]8;;\x1b\\\nnext\n",
		"a\x1b[38;2;1;2;3mcolor\x1b[0mb\n",
	}
	for input in inputs {
		data := transmute([]byte)input
		whole := stream_output(data, len(data))
		defer delete(whole)
		split := stream_output(data, 1)
		defer delete(split)
		testing.expectf(
			t,
			string(split[:]) == string(whole[:]),
			"chunk=1 %q != whole %q for %q",
			string(split[:]),
			string(whole[:]),
			input,
		)
	}
}
