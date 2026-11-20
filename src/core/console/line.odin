// Line-oriented progress buffer (M10.03).
//
// This file consumes the ANSI event stream from `ansi.odin` (M10.02) and
// assembles it into styled lines, applying the carriage-return / backspace /
// erase edits that programs use to render in-place progress on a single line.
// It is the log-window half of SPECS §12.5 (model A); the full terminal grid
// (model B) is M10.05-07.
//
// The Line_Buffer holds the current line as a sequence of display cells
// (rune + style). CR returns to column 0, backspace moves one column back,
// erase-in-line (CSI K) truncates, and LF flushes the current line. Text
// written at a column that already has a cell overwrites it, so a `\r`-based
// progress update leaves only its final form. Each flushed Line owns its
// `text` and `runs` (allocated with the buffer's allocator); free them with
// `line_destroy`.
//
// The buffer is bounded: at most `max_cells` cells per line. A write that
// would exceed the bound drops the overflowing runes and records them in
// `truncated` for diagnostics. Erase-display (CSI J mode 2) clears the current
// line and reports `cleared` so the caller can also clear previously emitted
// lines.
package console

import "base:runtime"

import errs "../errs"

DEFAULT_LINE_CELLS :: 64 * 1024
MAX_LINE_CELLS :: 4 * 1024 * 1024

// Cell is one display cell: a rune, the style it is rendered with, and the
// hyperlink it belongs to (an index into Line_Buffer.links, or -1).
Cell :: struct {
	r:     rune,
	style: Style,
	link:  i32,
}

// Run describes a uniform-style span of a line's text, in rune units.
Run :: struct {
	length: int,
	style:  Style,
}

// Link describes a hyperlink span of a line's text: a rune range and the URI
// it points to. Links are line-scoped; an OSC 8 hyperlink that is still open
// at a line feed is closed there.
Link :: struct {
	start:  int,
	length: int,
	uri:    []rune, // owned
}

// Line is a completed styled line. `text` is the visible content; `runs` is
// the sorted, non-overlapping style-run set covering it; `links` is the
// (possibly empty) hyperlink set. All three are owned by the caller; free with
// `line_destroy`.
Line :: struct {
	text:  []rune,
	runs:  []Run,
	links: []Link,
}

// Line_Buffer assembles terminal output into styled lines with progress
// editing. It is a fixed-location value; keep it at one address and do not
// copy it while it holds a partial line. The zero value is not initialized.
Line_Buffer :: struct {
	allocator:  runtime.Allocator,
	cells:      [dynamic]Cell,
	cursor:     int,
	style:      Style,
	max_cells:  int,
	truncated:  u64,
	links:      [dynamic][]rune, // owned URI table for the current line
	active_link: i32, // index into links, or -1 for no active hyperlink
}

// line_buffer_init prepares lb. A max_cells of 0 selects DEFAULT_LINE_CELLS.
line_buffer_init :: proc(lb: ^Line_Buffer, max_cells: int, allocator := context.allocator) -> errs.Error {
	if lb == nil {
		return errs.new(.Invalid_Input, "console: line buffer is nil", allocator = allocator)
	}
	resolved := max_cells
	if resolved == 0 {
		resolved = DEFAULT_LINE_CELLS
	}
	if resolved < 0 || resolved > MAX_LINE_CELLS {
		return errs.newf(.Resource_Limit, "console: line buffer cell budget %d out of range", resolved, allocator = allocator)
	}
	lb^ = {
		allocator = allocator,
		cells = make([dynamic]Cell, allocator),
		links = make([dynamic][]rune, allocator),
		max_cells = resolved,
		active_link = -1,
	}
	return {}
}

// line_buffer_destroy releases the buffer's storage. It does not free any
// Line values already flushed to the caller.
line_buffer_destroy :: proc(lb: ^Line_Buffer) {
	if lb == nil {
		return
	}
	clear_links(lb)
	delete(lb.cells)
	delete(lb.links)
	lb^ = {}
}

// line_buffer_feed consumes events, appending completed lines to out and
// setting cleared^ when an erase-display sequence requests clearing prior
// output. Flushed Line values are allocated with the buffer's allocator.
line_buffer_feed :: proc(lb: ^Line_Buffer, events: []Event, out: ^[dynamic]Line, cleared: ^bool) -> errs.Error {
	if lb == nil || lb.allocator.procedure == nil {
		return errs.new(.Invalid_Input, "console: line buffer is not initialized")
	}
	for e in events {
		switch v in e {
		case Text_Event:
			write_cells(lb, v.runes)
		case Style_Event:
			lb.style = v.style
		case Control_Event:
			switch v.rune {
			case '\r':
				lb.cursor = 0
			case '\n':
				flush_line(lb, out)
			case '\b':
				lb.cursor = max(0, lb.cursor - 1)
			case '\t':
				write_cells(lb, []rune{'\t'})
			case:
				// Other controls (BEL, NUL, ...) are ignored.
			}
		case Csi_Event:
			switch v.final {
			case 'K':
				erase_in_line(lb, v)
			case 'J':
				erase_in_display(lb, v, cleared)
			case:
				// Cursor movement and other CSI are terminal-grid features
				// (M10.07); ignored for the log window.
			}
		case Osc_Event:
			handle_osc(lb, v.payload)
		}
	}
	return {}
}

// line_buffer_flush emits the current partial line, if any, as a completed
// line. Use it at end-of-stream so trailing text without a newline is kept.
// Unlike a line-feed, a flush does not emit an empty trailing line.
line_buffer_flush :: proc(lb: ^Line_Buffer, out: ^[dynamic]Line) -> errs.Error {
	if lb == nil || lb.allocator.procedure == nil {
		return errs.new(.Invalid_Input, "console: line buffer is not initialized")
	}
	if len(lb.cells) > 0 {
		flush_line(lb, out)
	}
	return {}
}

// line_destroy frees a Line's owned text, runs, and links.
line_destroy :: proc(line: Line, allocator: runtime.Allocator) {
	delete(line.text, allocator)
	delete(line.runs, allocator)
	for link in line.links {
		delete(link.uri, allocator)
	}
	delete(line.links, allocator)
}

// write_cells writes runes at the cursor using the current style, overwriting
// existing cells and appending past the end. Overflow beyond max_cells is
// dropped and counted.
write_cells :: proc(lb: ^Line_Buffer, runes: []rune) {
	for r in runes {
		cell := Cell{r = r, style = lb.style, link = lb.active_link}
		if lb.cursor < len(lb.cells) {
			lb.cells[lb.cursor] = cell
		} else {
			if len(lb.cells) >= lb.max_cells {
				lb.truncated += 1
				continue
			}
			append(&lb.cells, cell)
		}
		lb.cursor += 1
	}
}

// erase_in_line applies CSI K (erase in line). mode 0 erases from the cursor
// to the end, 1 erases from the start to the cursor, 2 erases the whole line.
erase_in_line :: proc(lb: ^Line_Buffer, csi: Csi_Event) {
	mode := u32(0)
	if csi.param_count > 0 {
		mode = csi.params[0]
	}
	switch mode {
	case 0:
		if lb.cursor < len(lb.cells) {
			resize(&lb.cells, lb.cursor)
		}
	case 1:
		keep := len(lb.cells) - min(lb.cursor, len(lb.cells))
		copy(lb.cells[:], lb.cells[len(lb.cells) - keep:])
		resize(&lb.cells, keep)
		lb.cursor = 0
	case 2:
		resize(&lb.cells, 0)
		lb.cursor = 0
	}
}

// erase_in_display applies CSI J (erase in display) for the log window: mode 0
// erases from the cursor to the end of the current line; modes 1 and 2 clear
// the current line and (for mode 2) report that prior lines should be cleared.
erase_in_display :: proc(lb: ^Line_Buffer, csi: Csi_Event, cleared: ^bool) {
	mode := u32(0)
	if csi.param_count > 0 {
		mode = csi.params[0]
	}
	switch mode {
	case 0:
		if lb.cursor < len(lb.cells) {
			resize(&lb.cells, lb.cursor)
		}
	case 1:
		if cleared != nil {
			cleared^ = true
		}
	case 2:
		resize(&lb.cells, 0)
		lb.cursor = 0
		if cleared != nil {
			cleared^ = true
		}
	}
}

// flush_line emits the current line as a completed Line (including an empty
// line) and resets the cursor and hyperlink state.
flush_line :: proc(lb: ^Line_Buffer, out: ^[dynamic]Line) {
	line := build_line(lb)
	append(out, line)
	resize(&lb.cells, 0)
	lb.cursor = 0
	clear_links(lb)
}

// build_line converts the current cells into a Line (text plus coalesced
// style runs and hyperlink ranges). The result is allocated with the buffer's
// allocator.
build_line :: proc(lb: ^Line_Buffer) -> Line {
	n := len(lb.cells)
	text := make([]rune, n, lb.allocator)
	runs := make([dynamic]Run, lb.allocator)
	links := make([dynamic]Link, lb.allocator)
	last_link: i32 = -1
	for i in 0 ..< n {
		cell := lb.cells[i]
		text[i] = cell.r
		if len(runs) > 0 && style_equal(runs[len(runs) - 1].style, cell.style) {
			runs[len(runs) - 1].length += 1
		} else {
			append(&runs, Run{length = 1, style = cell.style})
		}
		if cell.link == last_link {
			if cell.link >= 0 {
				links[len(links) - 1].length += 1
			}
		} else if cell.link >= 0 {
			uri := make([]rune, len(lb.links[cell.link]), lb.allocator)
			copy(uri, lb.links[cell.link])
			append(&links, Link{start = i, length = 1, uri = uri})
			last_link = cell.link
		} else {
			last_link = cell.link
		}
	}
	return Line{text = text, runs = runs[:], links = links[:]}
}

// handle_osc applies an OSC payload to the line buffer. Hyperlinks open or
// close the active link; every other command is inert (the clipboard policy is
// applied by the consumer, not here).
handle_osc :: proc(lb: ^Line_Buffer, payload: []rune) {
	osc := osc_parse(payload)
	#partial switch o in osc {
	case Osc_Hyperlink:
		if len(o.uri) == 0 {
			lb.active_link = -1
		} else {
			uri := make([]rune, len(o.uri), lb.allocator)
			copy(uri, o.uri)
			append(&lb.links, uri)
			lb.active_link = i32(len(lb.links) - 1)
		}
	}
}

// clear_links frees the link URI table and closes the active link. Hyperlinks
// are line-scoped, so this runs at each flush.
clear_links :: proc(lb: ^Line_Buffer) {
	for uri in lb.links {
		delete(uri, lb.allocator)
	}
	resize(&lb.links, 0)
	lb.active_link = -1
}

// style_equal reports whether two styles render identically.
style_equal :: proc(a, b: Style) -> bool {
	return color_equal(a.fg, b.fg) &&
		color_equal(a.bg, b.bg) &&
		a.bold == b.bold &&
		a.dim == b.dim &&
		a.italic == b.italic &&
		a.underline == b.underline &&
		a.blink == b.blink &&
		a.reverse == b.reverse &&
		a.hidden == b.hidden &&
		a.strikethrough == b.strikethrough
}

// color_equal reports whether two colors are equal.
color_equal :: proc(a, b: Color) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .Default:
		return true
	case .Basic, .Palette:
		return a.index == b.index
	case .RGB:
		return a.rgb == b.rgb
	}
	return false
}
