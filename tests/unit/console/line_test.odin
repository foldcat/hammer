// Tests for M10.03: the line-oriented progress buffer. Byte sequences are
// decoded (M10.01) and parsed (M10.02), then assembled into styled lines with
// CR/backspace/erase editing applied.
package console_test

import "core:testing"

import console "hammer:core/console"

// delete_lines frees a line list and the text/runs each line owns.
delete_lines :: proc(lines: [dynamic]console.Line) {
	for line in lines {
		console.line_destroy(line, context.allocator)
	}
	delete(lines)
}

// collect_lines decodes and parses data, then assembles it into lines. It
// returns the completed lines and whether an erase-display was requested.
collect_lines :: proc(data: []byte) -> ([dynamic]console.Line, bool) {
	events := collect_events(data)
	defer delete_events(events)
	lb: console.Line_Buffer
	console.line_buffer_init(&lb, 0, context.allocator)
	defer console.line_buffer_destroy(&lb)
	lines := make([dynamic]console.Line, context.allocator)
	cleared: bool
	console.line_buffer_feed(&lb, events[:], &lines, &cleared)
	console.line_buffer_flush(&lb, &lines)
	return lines, cleared
}

expect_line_text :: proc(t: ^testing.T, line: console.Line, want: string) {
	testing.expectf(t, runes_is(line.text, want), "expected line %q, got %v", want, line.text)
}

expect_run :: proc(t: ^testing.T, run: console.Run, want_length: int, want_style: console.Style) {
	testing.expectf(t, run.length == want_length, "run length %d want %d", run.length, want_length)
	testing.expect(t, style_equal(run.style, want_style))
}

basic_fg_style :: proc(index: u8) -> console.Style {
	s := console.Style{}
	s.fg = console.Color{kind = .Basic, index = index}
	return s
}

@(test)
test_line_buffer_basic_lines :: proc(t: ^testing.T) {
	lines, cleared := collect_lines(transmute([]byte)string("hello\nworld\n"))
	defer delete_lines(lines)
	testing.expect(t, !cleared)
	testing.expect(t, len(lines) == 2)
	if len(lines) == 2 {
		expect_line_text(t, lines[0], "hello")
		expect_line_text(t, lines[1], "world")
	}
}

@(test)
test_line_buffer_carriage_return :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("foo\rbar\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "bar")
	}
}

@(test)
test_line_buffer_cr_partial_overwrite :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("hello\rhi\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "hillo")
	}
}

@(test)
test_line_buffer_backspace :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("abc\b\bd\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "adc")
	}
}

@(test)
test_line_buffer_erase_to_eol :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("hello\b\b\x1b[K\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "hel")
	}
}

@(test)
test_line_buffer_erase_whole_line :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("hello\x1b[2Kworld\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "world")
	}
}

@(test)
test_line_buffer_erase_start_to_cursor :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("hello\b\x1b[1K\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "o")
	}
}

@(test)
test_line_buffer_style_runs :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("\x1b[31mred\x1b[0mblue\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "redblue")
		testing.expect(t, len(lines[0].runs) == 2)
		if len(lines[0].runs) == 2 {
			expect_run(t, lines[0].runs[0], 3, basic_fg_style(1))
			expect_run(t, lines[0].runs[1], 4, console.Style{})
		}
	}
}

@(test)
test_line_buffer_overwrite_preserves_style :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("\x1b[31mred\r\x1b[32mgr\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "grd")
		testing.expect(t, len(lines[0].runs) == 2)
		if len(lines[0].runs) == 2 {
			expect_run(t, lines[0].runs[0], 2, basic_fg_style(2))
			expect_run(t, lines[0].runs[1], 1, basic_fg_style(1))
		}
	}
}

@(test)
test_line_buffer_erase_display_clears :: proc(t: ^testing.T) {
	lines, cleared := collect_lines(transmute([]byte)string("line1\nline2\x1b[2J\n"))
	defer delete_lines(lines)
	testing.expect(t, cleared)
	testing.expect(t, len(lines) == 2)
	if len(lines) == 2 {
		expect_line_text(t, lines[0], "line1")
		expect_line_text(t, lines[1], "")
	}
}

@(test)
test_line_buffer_flush_partial_line :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("no newline here"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "no newline here")
	}
}

@(test)
test_line_buffer_multiline_progress :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("a\rb\nc\rd\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 2)
	if len(lines) == 2 {
		expect_line_text(t, lines[0], "b")
		expect_line_text(t, lines[1], "d")
	}
}

@(test)
test_line_buffer_blank_lines :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("\n\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 2)
	if len(lines) == 2 {
		expect_line_text(t, lines[0], "")
		expect_line_text(t, lines[1], "")
	}
}

@(test)
test_line_buffer_tab_written_literally :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("a\tb\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "a\tb")
	}
}

@(test)
test_line_buffer_truncation :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("abcdefghijklm\n"))
	defer delete_events(events)
	lb: console.Line_Buffer
	console.line_buffer_init(&lb, 8, context.allocator)
	defer console.line_buffer_destroy(&lb)
	lines := make([dynamic]console.Line, context.allocator)
	defer delete_lines(lines)
	cleared: bool
	console.line_buffer_feed(&lb, events[:], &lines, &cleared)
	console.line_buffer_flush(&lb, &lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "abcdefgh")
	}
	testing.expect(t, lb.truncated == 5)
}

@(test)
test_line_buffer_cr_progress_bar :: proc(t: ^testing.T) {
	// A progress line that overwrites itself several times leaves only its
	// final form.
	lines, _ := collect_lines(transmute([]byte)string("0%\r25%\r50%\r100% done\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "100% done")
	}
}
