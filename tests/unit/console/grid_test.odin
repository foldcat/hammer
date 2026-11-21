// Tests for M10.07: the terminal grid (SPECS §12.5 model B). Byte sequences
// are decoded (M10.01) and parsed (M10.02), then applied to a Grid and drained
// to plain text. The terminal slave runs with output post-processing (ONLCR)
// on, so program newlines arrive as "\r\n"; LF alone keeps the column. The
// transcript ends at the current line without a trailing newline.
package console_test

import "core:testing"

import console "hammer:core/console"

// expect_grid feeds data through the grid (rows×cols) and asserts the rendered
// transcript (scrollback + visible screen) equals want.
expect_grid :: proc(t: ^testing.T, rows, cols: int, data: []byte, want: string) {
	events := collect_events(data)
	defer delete_events(events)
	g: console.Grid
	console.grid_init(&g, rows, cols, 0, context.allocator)
	defer console.grid_destroy(&g)
	console.grid_feed(&g, events[:])
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&g, &out)
	testing.expectf(t, string(out[:]) == want, "expected %q, got %q", want, string(out[:]))
}

// expect_grid_stream exercises the full decode → parse → grid path.
expect_grid_stream :: proc(t: ^testing.T, rows, cols: int, data: []byte, want: string) {
	s: console.Grid_Stream
	console.grid_stream_init(&s, rows, cols, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	console.grid_stream_feed(&s, data)
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == want, "expected %q, got %q", want, string(out[:]))
}

@(test)
test_grid_basic_lines :: proc(t: ^testing.T) {
	expect_grid(t, 24, 80, transmute([]byte)string("hello\r\nworld\r\n"), "hello\nworld")
}

@(test)
test_grid_lf_keeps_column :: proc(t: ^testing.T) {
	// A bare LF moves down without resetting the column (ONLCR is off here).
	expect_grid(t, 24, 80, transmute([]byte)string("hello\nworld"), "hello\n     world")
}

@(test)
test_grid_carriage_return_overwrites :: proc(t: ^testing.T) {
	expect_grid(t, 24, 80, transmute([]byte)string("foo\rbar\r\n"), "bar")
	expect_grid(t, 24, 80, transmute([]byte)string("hello\rhi\r\n"), "hillo")
}

@(test)
test_grid_backspace :: proc(t: ^testing.T) {
	expect_grid(t, 24, 80, transmute([]byte)string("abc\b\bd\r\n"), "adc")
}

@(test)
test_grid_cursor_movement :: proc(t: ^testing.T) {
	// CUB: move left then overwrite.
	expect_grid(t, 24, 80, transmute([]byte)string("hello\x1b[2DX\r\n"), "helXo")
	// CUP: move to (1,1) and overwrite the first column of a filled screen.
	expect_grid(t, 24, 80, transmute([]byte)string("ab\r\ncd\x1b[1;1HX\r\n"), "Xb\ncd")
}

@(test)
test_grid_erase_line :: proc(t: ^testing.T) {
	// erase from cursor to end of line.
	expect_grid(t, 24, 80, transmute([]byte)string("hello\b\b\x1b[K\r\n"), "hel")
	// erase the whole line, then rewrite from column 0.
	expect_grid(t, 24, 80, transmute([]byte)string("hello\x1b[2K\rworld\r\n"), "world")
}

@(test)
test_grid_erase_display :: proc(t: ^testing.T) {
	// CSI 2J clears the whole screen.
	expect_grid(t, 24, 80, transmute([]byte)string("line1\r\nline2\x1b[2J"), "")
	// erase from cursor to end of screen: keep line1, drop line2.
	expect_grid(t, 24, 80, transmute([]byte)string("line1\r\nline2\x1b[1;1H\x1b[1B\x1b[J"), "line1")
}

@(test)
test_grid_scroll_transcript :: proc(t: ^testing.T) {
	// A 2-row screen with three lines keeps the scrolled-off lines in the
	// transcript's scrollback.
	expect_grid(t, 2, 80, transmute([]byte)string("one\r\ntwo\r\nthree\r\n"), "one\ntwo\nthree")
	expect_grid(t, 2, 80, transmute([]byte)string("one\r\ntwo\r\nthree\r\nfour\r\n"), "one\ntwo\nthree\nfour")
}

@(test)
test_grid_wrap_pending :: proc(t: ^testing.T) {
	// A line exactly cols wide does not leave a phantom blank row.
	expect_grid(t, 3, 4, transmute([]byte)string("1234\r\n"), "1234")
	// A line wider than cols wraps onto the next row.
	expect_grid(t, 3, 4, transmute([]byte)string("12345\r\n"), "1234\n5")
}

@(test)
test_grid_cursor_position_absolute :: proc(t: ^testing.T) {
	expect_grid(t, 3, 80, transmute([]byte)string("....\x1b[3G!\r\n"), "..!.")
	expect_grid(t, 3, 80, transmute([]byte)string("\x1b[2;2H*\r\n"), "\n *")
}

@(test)
test_grid_tab_stops :: proc(t: ^testing.T) {
	// Tab advances to the next 8-column stop; the gap renders as spaces.
	expect_grid(t, 24, 80, transmute([]byte)string("a\tb\r\n"), "a       b")
}

@(test)
test_grid_stream_decodes_and_parses :: proc(t: ^testing.T) {
	expect_grid_stream(t, 24, 80, transmute([]byte)string("hi\x1b[31mthere\r\n"), "hithere")
}

@(test)
test_grid_stream_chunk_boundaries :: proc(t: ^testing.T) {
	// A multi-byte sequence split across feeds decodes identically.
	s: console.Grid_Stream
	console.grid_stream_init(&s, 24, 80, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	// "é" as UTF-8, split across two feeds.
	console.grid_stream_feed(&s, []byte{0xc3})
	console.grid_stream_feed(&s, []byte{0xa9, '\r', '\n'})
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == "é", "got %q", string(out[:]))
}

@(test)
test_grid_clear_screen_and_scrollback :: proc(t: ^testing.T) {
	// `clear` sends \x1b[H\x1b[2J\x1b[3J: cursor home, clear the screen, clear
	// the scrollback. With a populated scrollback the result must be only the
	// new prompt.
	expect_grid(t, 3, 80, transmute([]byte)string("a\r\nb\r\nc\r\nd\r\n\x1b[H\x1b[2J\x1b[3Jp"), "p")
}

@(test)
test_grid_real_clear_sequence :: proc(t: ^testing.T) {
	// The exact bytes bash-as-sh + `clear` emit (bracketed-paste toggles,
	// echo, and the clear escape), captured from a live PTY. The transcript
	// must end at the single fresh prompt, with no leftover line above it.
	data := transmute([]byte)string("\x1b[?2004hsh-5.3$ clear\r\n\x1b[?2004l\r\x1b[H\x1b[2J\x1b[3J\x1b[?2004hsh-5.3$ ")
	expect_grid(t, 24, 80, data, "sh-5.3$ ")
}

@(test)
test_grid_echo_command_sequence :: proc(t: ^testing.T) {
	// The exact bytes bash-as-sh emits for a simple command (prompt, echo,
	// Enter, output, prompt). The transcript must be three lines: the command
	// line, the output, and one fresh prompt — not a duplicated prompt.
	data := transmute([]byte)string("\x1b[?2004hsh-5.3$ echo terminal-ok\r\n\x1b[?2004l\rterminal-ok\r\n\x1b[?2004hsh-5.3$ ")
	expect_grid(t, 24, 80, data, "sh-5.3$ echo terminal-ok\nterminal-ok\nsh-5.3$ ")
}

@(test)
test_grid_echo_command_chunked :: proc(t: ^testing.T) {
	// The same command, fed in the chunks the terminal's read loop produces
	// (prompt, echoed keystrokes, Enter, output). The grid state must be
	// chunk-independent: still three lines, one prompt.
	s: console.Grid_Stream
	console.grid_stream_init(&s, 24, 80, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?2004hsh-5.3$ "))
	console.grid_stream_feed(&s, transmute([]byte)string("echo terminal-ok"))
	console.grid_stream_feed(&s, transmute([]byte)string("\r\n"))
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?2004l\rterminal-ok\r\n\x1b[?2004hsh-5.3$ "))
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == "sh-5.3$ echo terminal-ok\nterminal-ok\nsh-5.3$ ", "got %q", string(out[:]))
}

@(test)
test_grid_alternate_screen :: proc(t: ^testing.T) {
	// Entering the alternate screen clears it; leaving restores the main screen.
	expect_grid(t, 24, 80, transmute([]byte)string("main\r\n\x1b[?1049hALT\x1b[?1049l"), "main")
	// Content written while in the alternate screen does not leak into main.
	expect_grid(t, 24, 80, transmute([]byte)string("one\r\ntwo\r\n\x1b[?1049hvi\r\n\x1b[?1049l"), "one\ntwo")
}

@(test)
test_grid_alternate_screen_preserves_scrollback :: proc(t: ^testing.T) {
	// The main screen's scrollback survives an alternate-screen round trip.
	expect_grid(
		t,
		2,
		80,
		transmute([]byte)string("one\r\ntwo\r\nthree\r\n\x1b[?1049hX\x1b[?1049l"),
		"one\ntwo\nthree",
	)
}

@(test)
test_grid_resize_rewraps :: proc(t: ^testing.T) {
	s: console.Grid_Stream
	console.grid_stream_init(&s, 2, 8, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	console.grid_stream_feed(&s, transmute([]byte)string("abcdefgh\r\n"))
	// A single full line re-wraps into two lines at the narrower width.
	console.grid_resize(&s.grid, 2, 4)
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == "abcd\nefgh", "got %q", string(out[:]))
}

@(test)
test_grid_resize_shrinks_height_into_scrollback :: proc(t: ^testing.T) {
	s: console.Grid_Stream
	console.grid_stream_init(&s, 3, 80, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	console.grid_stream_feed(&s, transmute([]byte)string("a\r\nb\r\nc\r\n"))
	console.grid_resize(&s.grid, 1, 80)
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == "a\nb\nc", "got %q", string(out[:]))
}

@(test)
test_grid_resize_while_in_alternate_screen :: proc(t: ^testing.T) {
	// Resizing while the alternate screen is active must also reflow the parked
	// main screen, so exiting the alternate screen restores it at the new size
	// (well-formed, no stale-dimension mismatch).
	s: console.Grid_Stream
	console.grid_stream_init(&s, 2, 80, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	console.grid_stream_feed(&s, transmute([]byte)string("hello\r\n"))
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?1049h"))
	console.grid_stream_feed(&s, transmute([]byte)string("vi"))
	console.grid_resize(&s.grid, 2, 3)
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?1049l"))
	out := make([dynamic]byte, context.allocator)
	defer delete(out)
	console.grid_append_text(&s.grid, &out)
	testing.expectf(t, string(out[:]) == "hel\nlo", "got %q", string(out[:]))
}

@(test)
test_grid_cursor_visibility_and_position :: proc(t: ^testing.T) {
	s: console.Grid_Stream
	console.grid_stream_init(&s, 24, 80, 0, context.allocator)
	defer console.grid_stream_destroy(&s)
	testing.expect(t, console.grid_cursor_visible(&s.grid))
	console.grid_stream_feed(&s, transmute([]byte)string("hello"))
	testing.expect(t, console.grid_cursor_row(&s.grid) == 0)
	testing.expect(t, console.grid_cursor_col(&s.grid) == 5)
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?25l"))
	testing.expect(t, !console.grid_cursor_visible(&s.grid))
	console.grid_stream_feed(&s, transmute([]byte)string("\x1b[?25h"))
	testing.expect(t, console.grid_cursor_visible(&s.grid))
}
