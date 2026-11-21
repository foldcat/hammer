// Terminal grid (SPECS §12.5 model B) — M10.07.
//
// The model-A log stream (line.odin / stream.odin) assembles process output
// into completed lines for a scrollable log window; it deliberately holds a
// partial line until a newline arrives. An interactive terminal needs the
// current line to update in place: a prompt, an echoed keystroke, a progress
// bar, and a full-screen program all rewrite the screen without a newline.
//
// This file is the grid half of model B: a fixed rows×cols cell screen with a
// cursor, the ANSI control sequences that move the cursor and edit the screen
// (CUP/CUU/CUD/CUF/CUB/CHA/VPA, erase-in-line/display, insert/delete line and
// character, scroll), and a bounded scrollback of lines that scrolled off the
// top. It consumes the same Event stream as Line_Buffer (from ansi.odin), so
// it reuses the UTF-8 decoder and the ANSI parser unchanged.
//
// The Grid does not render: callers drain it into text with `grid_append_text`
// (scrollback plus the visible screen). Styles are carried on cells but not
// emitted as text here; per-run color rendering is a later milestone (SPECS
// §12.7). The alternate screen (CSI ?1049h/l), DECTCEM cursor visibility
// (CSI ?25h/l), and resize (grid_resize) are implemented; window sizing itself
// lives in the view layer.
package console

import "base:runtime"

import errs "../errs"

DEFAULT_GRID_ROWS :: 24
DEFAULT_GRID_COLS :: 80
MAX_GRID_ROWS :: 512
MAX_GRID_COLS :: 1024
DEFAULT_SCROLLBACK_LINES :: 10000
MAX_SCROLLBACK_LINES :: 1_000_000

// Style_Run is a span of the styled transcript (SPECS §12.7: styles stored
// separately from text). start/end are byte offsets into the text emitted by
// grid_append_styled; `style` is the resolved SGR style for every byte in the
// span. Runs are emitted in order and never overlap; newline bytes fall between
// runs (they are line separators, not styled cells).
Style_Run :: struct {
	start: int,
	end:   int,
	style: Style,
}

// Charset_Kind tags the active G0 character set (SCS designation). The grid
// always emits UTF-8, so the only set it must translate is DEC Special
// Graphics (the VT100/ACS line-drawing set selected by ESC ( 0); every other
// designator renders as plain ASCII.
Charset_Kind :: enum u8 {
	Ascii,
	Dec_Special_Graphics,
}

// Grid is a fixed rows×cols terminal screen plus a bounded scrollback. It is a
// fixed-location value: keep it at one address and do not copy it.
Grid :: struct {
	allocator: runtime.Allocator,
	rows:      int,
	cols:      int,
	// cells is row-major, len == rows*cols. An empty cell has r == 0.
	cells:       [dynamic]Cell,
	cursor_row:  int,
	cursor_col:  int,
	wrap_pending: bool, // a full line was written; the next char wraps
	style:       Style,
	g0_charset:  Charset_Kind,
	// scrollback holds completed lines scrolled off the top, oldest first.
	// Each Line owns its text (runs/links are empty).
	scrollback:     [dynamic]Line,
	max_scrollback: int,
	dirty:          bool,
	// cursor_visible tracks DECTCEM (CSI ?25h/l): whether the terminal cursor
	// is rendered. It defaults to true.
	cursor_visible: bool,
	// application_cursor tracks DECCKM (CSI ?1h/l): whether arrow keys use the
	// application (SS3) encoding. The caller consults it when forwarding keys.
	application_cursor: bool,
	// scroll_top/scroll_bottom bound the scrolling region (DECSTBM, CSI r),
	// 0-based and inclusive. They default to the whole screen and reset on
	// resize and alternate-screen switches.
	scroll_top:    int,
	scroll_bottom: int,
	// mouse_reporting tracks DECSET 1000 (button-event tracking) and
	// mouse_sgr tracks 1006 (SGR encoding); the caller consults both when
	// deciding whether and how to forward pointer events to the child.
	mouse_reporting: bool,
	mouse_sgr:       bool,
	// DECSC (ESC 7) saves the cursor position, pending wrap, and style; DECRC
	// (ESC 8) restores them.
	decsc_row:          int,
	decsc_col:          int,
	decsc_wrap_pending: bool,
	decsc_style:        Style,
	// Alternate screen (CSI ?1049h/l). While using_alternate is true, `cells`
	// and `scrollback` hold the alternate screen and `saved_*` hold the saved
	// main screen (swapped back on exit).
	using_alternate:    bool,
	saved_cells:        [dynamic]Cell,
	saved_scrollback:   [dynamic]Line,
	saved_cursor_row:   int,
	saved_cursor_col:   int,
	saved_wrap_pending: bool,
}

// grid_init prepares an empty grid. rows/cols are clamped to their bounds;
// max_scrollback of 0 selects DEFAULT_SCROLLBACK_LINES.
grid_init :: proc(
	g: ^Grid,
	rows, cols, max_scrollback: int,
	allocator := context.allocator,
) -> errs.Error {
	if g == nil {
		return errs.new(.Invalid_Input, "console: grid is nil", allocator = allocator)
	}
	r := rows
	c := cols
	m := max_scrollback
	if r <= 0 {
		r = DEFAULT_GRID_ROWS
	}
	if c <= 0 {
		c = DEFAULT_GRID_COLS
	}
	if m <= 0 {
		m = DEFAULT_SCROLLBACK_LINES
	}
	r = clamp(r, 1, MAX_GRID_ROWS)
	c = clamp(c, 1, MAX_GRID_COLS)
	m = clamp(m, 1, MAX_SCROLLBACK_LINES)
	g^ = {
		allocator = allocator,
		rows = r,
		cols = c,
		cells = make([dynamic]Cell, r * c, allocator),
		scrollback = make([dynamic]Line, allocator),
		max_scrollback = m,
		cursor_visible = true,
		scroll_top = 0,
		scroll_bottom = r - 1,
	}
	return {}
}

// grid_destroy releases the cell buffer and the scrollback lines (both the
// active screen and any saved main screen).
grid_destroy :: proc(g: ^Grid) {
	if g == nil {
		return
	}
	for line in g.scrollback {
		line_destroy(line, g.allocator)
	}
	delete(g.scrollback)
	delete(g.cells)
	for line in g.saved_scrollback {
		line_destroy(line, g.allocator)
	}
	delete(g.saved_scrollback)
	delete(g.saved_cells)
	g^ = {}
}

// grid_dirty reports whether the grid changed since it was last cleared.
grid_dirty :: proc(g: ^Grid) -> bool {
	return g != nil && g.dirty
}

// grid_clear_dirty clears the dirty flag.
grid_clear_dirty :: proc(g: ^Grid) {
	if g != nil {
		g.dirty = false
	}
}

// grid_rows / grid_cols report the screen dimensions.
grid_rows :: proc(g: ^Grid) -> int {
	return g.rows
}
grid_cols :: proc(g: ^Grid) -> int {
	return g.cols
}

// grid_cursor_row / grid_cursor_col report the terminal cursor's 0-based
// screen position (clamped to the screen by all cursor movement).
grid_cursor_row :: proc(g: ^Grid) -> int {
	if g == nil {
		return 0
	}
	return g.cursor_row
}
grid_cursor_col :: proc(g: ^Grid) -> int {
	if g == nil {
		return 0
	}
	return g.cursor_col
}

// grid_cursor_visible reports whether the terminal cursor is shown (DECTCEM).
grid_cursor_visible :: proc(g: ^Grid) -> bool {
	return g != nil && g.cursor_visible
}

// grid_application_cursor reports whether DECCKM (application cursor keys) is
// set; the caller uses it to pick the arrow-key encoding.
grid_application_cursor :: proc(g: ^Grid) -> bool {
	return g != nil && g.application_cursor
}

// grid_mouse_reporting reports whether DECSET 1000 (button-event tracking) is
// set, and grid_mouse_sgr whether 1006 (SGR encoding) is set.
grid_mouse_reporting :: proc(g: ^Grid) -> bool {
	return g != nil && g.mouse_reporting
}
grid_mouse_sgr :: proc(g: ^Grid) -> bool {
	return g != nil && g.mouse_sgr
}

// grid_scrollback_len reports how many completed lines have scrolled off the
// top of the active screen. The transcript is scrollback + visible rows, so a
// visible screen row r maps to document line scrollback_len + r.
grid_scrollback_len :: proc(g: ^Grid) -> int {
	if g == nil {
		return 0
	}
	return len(g.scrollback)
}

// grid_feed consumes parsed ANSI events, updating the screen. It marks the
// grid dirty whenever it receives any event (a no-op control is still a change
// the caller must re-render; callers batch a frame's worth of output).
grid_feed :: proc(g: ^Grid, events: []Event) {
	if g == nil || len(events) == 0 {
		return
	}
	g.dirty = true
	for e in events {
		switch v in e {
		case Text_Event:
			grid_write(g, v.runes)
		case Style_Event:
			g.style = v.style
		case Control_Event:
			grid_control(g, v.rune)
		case Csi_Event:
			grid_csi(g, v)
		case Osc_Event:
			// Hyperlinks are a model-A/log concern; the grid ignores OSC.
		case Escape_Event:
			grid_escape(g, v.rune)
		case Charset_Event:
			grid_charset(g, v.target, v.designator)
		}
	}
}

// grid_append_text appends the grid's visible content — scrollback lines
// followed by the screen rows up to the last non-empty one — as UTF-8 text to
// out. Each line except the final (current) one is followed by '\n', so the
// text ends at the cursor's position on the last visible line rather than on a
// phantom trailing blank line. An entirely empty screen appends nothing. This
// is the plain-text transcript; styles are not emitted.
grid_append_text :: proc(g: ^Grid, out: ^[dynamic]byte) {
	if g == nil {
		return
	}
	for line in g.scrollback {
		for r in line.text {
			buf: [4]byte
			n := encode_utf8(r, buf[:])
			append(out, ..buf[:n])
		}
		append(out, '\n')
	}
	last_row := grid_last_non_empty_row(g)
	for row in 0 ..= last_row {
		grid_append_row_text(g, out, row)
		if row < last_row {
			append(out, '\n')
		}
	}
}

// grid_append_styled is grid_append_text plus a parallel style-run list: out
// receives the same bytes, and runs receives Style_Run spans (byte offsets into
// out) covering every styled byte. Scrollback lines carry their coalesced runs;
// visible rows are built with grid_row_line. Callers that only need plain text
// use grid_append_text.
grid_append_styled :: proc(g: ^Grid, out: ^[dynamic]byte, runs: ^[dynamic]Style_Run) {
	if g == nil {
		return
	}
	for line in g.scrollback {
		grid_append_line_styled(out, runs, line.text, line.runs)
		append(out, '\n')
	}
	last_row := grid_last_non_empty_row(g)
	for row in 0 ..= last_row {
		line := grid_row_line(g, row)
		grid_append_line_styled(out, runs, line.text, line.runs)
		line_destroy(line, g.allocator)
		if row < last_row {
			append(out, '\n')
		}
	}
}

// grid_append_line_styled appends text (UTF-8) and style runs for one line.
// `text` and `runs` are parallel: runs' lengths are in runes and cover text.
grid_append_line_styled :: proc(out: ^[dynamic]byte, runs: ^[dynamic]Style_Run, text: []rune, run_list: []Run) {
	rune_index := 0
	for run in run_list {
		start := len(out)
		for _ in 0 ..< run.length {
			buf: [4]byte
			n := encode_utf8(text[rune_index], buf[:])
			append(out, ..buf[:n])
			rune_index += 1
		}
		append(runs, Style_Run{start = start, end = len(out), style = run.style})
	}
}

// --- Resize and alternate screen -----------------------------------------

// grid_resize reflows the grid to rows×cols, re-wrapping the visible screen at
// the new width and preserving scrollback. It clamps to the same bounds as
// grid_init and is a no-op when the size is unchanged. Resize only reflows the
// local grid; notifying the child of the new window size (SIGWINCH on Unix) is
// the caller's job. When the screen grows, blank rows are left at the bottom
// (scrollback lines are not pulled back in); the child's SIGWINCH redraw
// repaints authoritatively. Each source row is re-emitted as a hard line, so
// soft-wrapped runs are not re-joined — the grid does not track wrap flags.
// When the alternate screen is active, the parked main screen is reflowed too
// so it is still well-formed (and at the right size) on exit.
grid_resize :: proc(g: ^Grid, rows, cols: int) {
	if g == nil {
		return
	}
	r := clamp(rows, 1, MAX_GRID_ROWS)
	c := clamp(cols, 1, MAX_GRID_COLS)
	if r == g.rows && c == g.cols {
		return
	}
	old_rows := g.rows
	old_cols := g.cols
	g.rows = r
	g.cols = c
	g.scroll_top = 0
	g.scroll_bottom = r - 1

	grid_reflow_active(g, old_rows, old_cols)
	if g.using_alternate {
		grid_swap_active_and_saved(g)
		grid_reflow_active(g, old_rows, old_cols)
		grid_swap_active_and_saved(g)
	}
}

// grid_reflow_active reflows the active screen (g.cells and g.scrollback) from
// old_rows×old_cols to the current g.rows×g.cols, re-wrapping each source row
// and preserving scrollback. It snapshots using the old column stride before
// reallocating cells at the new size.
grid_reflow_active :: proc(g: ^Grid, old_rows, old_cols: int) {
	last := grid_last_non_empty_row_stride(g, old_rows, old_cols)
	visible := make([dynamic]Line, 0, max(0, last + 1), g.allocator)
	for row in 0 ..= last {
		append(&visible, grid_row_line_stride(g, row, old_cols))
	}
	old_cursor_row := g.cursor_row
	old_cursor_col := g.cursor_col

	// Rebuild the cell buffer at the new size, preserving scrollback.
	delete(g.cells)
	g.cells = make([dynamic]Cell, g.rows * g.cols, g.allocator)
	g.cursor_row = 0
	g.cursor_col = 0
	g.wrap_pending = false
	// Re-write verbatim: the snapshotted runes are already translated, so a
	// still-selected DEC Special Graphics set must not re-translate literal
	// ASCII (e.g. 'q'/'x' in a command line) into box-drawing glyphs. The
	// child's SIGWINCH redraw re-selects the set as needed.
	g.g0_charset = .Ascii

	for line, index in visible {
		g.cursor_col = 0
		g.wrap_pending = false
		grid_write(g, line.text)
		if index < len(visible) - 1 {
			grid_line_feed(g)
		}
		line_destroy(line, g.allocator)
	}
	delete(visible)

	// Best-effort cursor restoration (clamped); the child's SIGWINCH redraw
	// repositions it authoritatively.
	g.cursor_row = clamp(old_cursor_row, 0, g.rows - 1)
	g.cursor_col = clamp(old_cursor_col, 0, g.cols - 1)
	g.wrap_pending = false
	g.dirty = true
}

// grid_swap_active_and_saved exchanges the active screen with the parked main
// screen (the alternate-screen save). Ownership of each cell/scrollback buffer
// moves with the swap; no allocation is performed.
grid_swap_active_and_saved :: proc(g: ^Grid) {
	g.cells, g.saved_cells = g.saved_cells, g.cells
	g.scrollback, g.saved_scrollback = g.saved_scrollback, g.scrollback
	g.cursor_row, g.saved_cursor_row = g.saved_cursor_row, g.cursor_row
	g.cursor_col, g.saved_cursor_col = g.saved_cursor_col, g.cursor_col
	g.wrap_pending, g.saved_wrap_pending = g.saved_wrap_pending, g.wrap_pending
}

// grid_switch_alternate enters (on=true) or leaves (on=false) the alternate
// screen (CSI ?1049h/l). Entering saves the main screen and presents a cleared
// screen with the cursor home; leaving discards the alternate screen and
// restores the main screen. It is a no-op when already in the target state.
grid_switch_alternate :: proc(g: ^Grid, on: bool) {
	if g == nil || on == g.using_alternate {
		return
	}
	if on {
		g.saved_cells = g.cells
		g.saved_scrollback = g.scrollback
		g.saved_cursor_row = g.cursor_row
		g.saved_cursor_col = g.cursor_col
		g.saved_wrap_pending = g.wrap_pending
		g.cells = make([dynamic]Cell, g.rows * g.cols, g.allocator)
		g.scrollback = make([dynamic]Line, g.allocator)
		g.cursor_row = 0
		g.cursor_col = 0
		g.wrap_pending = false
		g.scroll_top = 0
		g.scroll_bottom = g.rows - 1
		g.using_alternate = true
	} else {
		for line in g.scrollback {
			line_destroy(line, g.allocator)
		}
		delete(g.scrollback)
		delete(g.cells)
		g.cells = g.saved_cells
		g.scrollback = g.saved_scrollback
		g.cursor_row = g.saved_cursor_row
		g.cursor_col = g.saved_cursor_col
		g.wrap_pending = g.saved_wrap_pending
		g.saved_cells = {}
		g.saved_scrollback = {}
		g.scroll_top = 0
		g.scroll_bottom = g.rows - 1
		g.using_alternate = false
	}
}

// --- Internals -----------------------------------------------------------

cell_ptr :: proc(g: ^Grid, row, col: int) -> ^Cell {
	return &g.cells[row * g.cols + col]
}

cell_at :: proc(g: ^Grid, row, col: int) -> Cell {
	return g.cells[row * g.cols + col]
}

// cell_at_stride reads a cell using an explicit column stride, for snapshots
// taken against a screen whose width differs from g.cols (reflow).
cell_at_stride :: proc(g: ^Grid, row, col, cols: int) -> Cell {
	return g.cells[row * cols + col]
}

// grid_write writes printable runes at the cursor with the current style,
// wrapping and scrolling as needed.
grid_write :: proc(g: ^Grid, runes: []rune) {
	for r in runes {
		if r == 0 {
			continue
		}
		cr := r
		if g.g0_charset == .Dec_Special_Graphics {
			cr = dec_special_graphics(cr)
		}
		if g.wrap_pending {
			grid_wrap(g)
		}
		c := cell_ptr(g, g.cursor_row, g.cursor_col)
		c^ = Cell{r = cr, style = g.style, link = -1}
		g.cursor_col += 1
		if g.cursor_col >= g.cols {
			g.cursor_col = g.cols - 1
			g.wrap_pending = true
		}
	}
}

// grid_wrap moves the cursor to the start of the next line (the auto-wrap the
// pending flag triggers), scrolling when it passes the bottom edge.
grid_wrap :: proc(g: ^Grid) {
	g.cursor_col = 0
	g.wrap_pending = false
	g.cursor_row += 1
	if g.cursor_row >= g.rows {
		g.cursor_row = g.rows - 1
		grid_scroll_up(g)
	}
}

// grid_line_feed moves down one line, scrolling at the bottom margin of the
// scrolling region. Explicit cursor movement (including LF) cancels any pending
// wrap.
grid_line_feed :: proc(g: ^Grid) {
	g.wrap_pending = false
	g.cursor_row += 1
	if g.cursor_row > g.scroll_bottom {
		g.cursor_row = g.scroll_bottom
		grid_scroll_up(g)
	}
}

grid_control :: proc(g: ^Grid, r: rune) {
	switch r {
	case '\r':
		g.wrap_pending = false
		g.cursor_col = 0
	case '\n':
		grid_line_feed(g)
	case '\b':
		g.wrap_pending = false
		g.cursor_col = max(0, g.cursor_col - 1)
	case '\t':
		g.wrap_pending = false
		g.cursor_col = min(g.cols - 1, g.cursor_col + (8 - (g.cursor_col % 8)))
	case:
		// Other controls are ignored.
	}
}

// grid_escape handles single-character escapes (ESC + one byte): DECSC/DECRC
// (cursor save/restore), IND/NEL (index/next line), and RI (reverse index).
grid_escape :: proc(g: ^Grid, r: rune) {
	switch r {
	case '7': // DECSC — save cursor position and style
		g.decsc_row = g.cursor_row
		g.decsc_col = g.cursor_col
		g.decsc_wrap_pending = g.wrap_pending
		g.decsc_style = g.style
	case '8': // DECRC — restore cursor position and style
		g.cursor_row = clamp(g.decsc_row, 0, g.rows - 1)
		g.cursor_col = clamp(g.decsc_col, 0, g.cols - 1)
		g.wrap_pending = g.decsc_wrap_pending
		g.style = g.decsc_style
	case 'D': // IND — index (move down, scrolling at the bottom)
		grid_line_feed(g)
	case 'E': // NEL — next line (CR + LF)
		g.wrap_pending = false
		g.cursor_col = 0
		grid_line_feed(g)
	case 'M': // RI — reverse index (move up, scrolling down at the top)
		g.wrap_pending = false
		if g.cursor_row == g.scroll_top {
			grid_scroll_down(g)
		} else {
			g.cursor_row -= 1
		}
	case:
		// Other single-character escapes are ignored deterministically.
	}
}

// grid_charset applies a character-set designation/selection event. Only the
// G0 set (ESC ( X) affects rendering, and only DEC Special Graphics (X = '0')
// changes how runes are written; every other designation maps back to ASCII.
// G1/G2/G3 and ESC % (UTF-8 selection) are no-ops because the grid always
// emits UTF-8 and does not implement shift-out/shift-in switching.
grid_charset :: proc(g: ^Grid, target, designator: rune) {
	if target == '(' {
		g.g0_charset = designator == '0' ? .Dec_Special_Graphics : .Ascii
	}
}

// dec_special_graphics translates the DEC Special Graphics (VT100/ACS) variant
// of an ASCII rune to its Unicode box-drawing/typographic equivalent. Runes
// without a variant are returned unchanged.
dec_special_graphics :: proc(r: rune) -> rune {
	switch r {
	case '`':
		return '\u25c6' // BLACK DIAMOND
	case 'a':
		return '\u2592' // MEDIUM SHADE
	case 'b':
		return '\u2409' // SYMBOL FOR HORIZONTAL TABULATION
	case 'c':
		return '\u240c' // SYMBOL FOR FORM FEED
	case 'd':
		return '\u240d' // SYMBOL FOR CARRIAGE RETURN
	case 'e':
		return '\u240a' // SYMBOL FOR LINE FEED
	case 'f':
		return '\u00b0' // DEGREE SIGN
	case 'g':
		return '\u00b1' // PLUS-MINUS SIGN
	case 'h':
		return '\u2424' // SYMBOL FOR NEWLINE
	case 'i':
		return '\u240b' // SYMBOL FOR VERTICAL TABULATION
	case 'j':
		return '\u2518' // BOX DRAWINGS LIGHT UP AND LEFT
	case 'k':
		return '\u2510' // BOX DRAWINGS LIGHT DOWN AND LEFT
	case 'l':
		return '\u250c' // BOX DRAWINGS LIGHT DOWN AND RIGHT
	case 'm':
		return '\u2514' // BOX DRAWINGS LIGHT UP AND RIGHT
	case 'n':
		return '\u253c' // BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
	case 'o':
		return '\u23ba' // HORIZONTAL SCAN LINE-1
	case 'p':
		return '\u23bb' // HORIZONTAL SCAN LINE-3
	case 'q':
		return '\u2500' // BOX DRAWINGS LIGHT HORIZONTAL
	case 'r':
		return '\u23bc' // HORIZONTAL SCAN LINE-7
	case 's':
		return '\u23bd' // HORIZONTAL SCAN LINE-9
	case 't':
		return '\u251c' // BOX DRAWINGS LIGHT VERTICAL AND RIGHT
	case 'u':
		return '\u2524' // BOX DRAWINGS LIGHT VERTICAL AND LEFT
	case 'v':
		return '\u2534' // BOX DRAWINGS LIGHT UP AND HORIZONTAL
	case 'w':
		return '\u252c' // BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
	case 'x':
		return '\u2502' // BOX DRAWINGS LIGHT VERTICAL
	case 'y':
		return '\u2264' // LESS-THAN OR EQUAL TO
	case 'z':
		return '\u2265' // GREATER-THAN OR EQUAL TO
	case '{':
		return '\u03c0' // GREEK SMALL LETTER PI
	case '|':
		return '\u2260' // NOT EQUAL TO
	case '}':
		return '\u00a3' // POUND SIGN
	case '~':
		return '\u00b7' // MIDDLE DOT
	case '_':
		return '\u00a0' // NO-BREAK SPACE
	case '0':
		return '\u2588' // FULL BLOCK
	}
	return r
}

// csi_param returns CSI parameter i (0-based), or def when absent.
csi_param :: proc(csi: Csi_Event, i, def: int) -> int {
	if i < int(csi.param_count) {
		return int(csi.params[i])
	}
	return def
}

// csi_count returns CSI parameter i as a repeat count. The ANSI default for
// count-based sequences is 1, and the parser represents a missing parameter as
// 0, so both a missing and an explicit 0 resolve to 1.
csi_count :: proc(csi: Csi_Event, i: int) -> int {
	return max(1, csi_param(csi, i, 1))
}

// grid_move_cursor clears any pending wrap; explicit addressing supersedes it.
grid_move_cursor :: proc(g: ^Grid) {
	g.wrap_pending = false
}

grid_csi :: proc(g: ^Grid, csi: Csi_Event) {
	switch csi.final {
	case 'A': // CUU — cursor up
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_row = max(0, g.cursor_row - n)
	case 'B': // CUD — cursor down
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_row = min(g.rows - 1, g.cursor_row + n)
	case 'C': // CUF — cursor right
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_col = min(g.cols - 1, g.cursor_col + n)
	case 'D': // CUB — cursor left
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_col = max(0, g.cursor_col - n)
	case 'E': // CNL — cursor next line
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_row = min(g.rows - 1, g.cursor_row + n)
		g.cursor_col = 0
	case 'F': // CPL — cursor previous line
		grid_move_cursor(g)
		n := csi_count(csi, 0)
		g.cursor_row = max(0, g.cursor_row - n)
		g.cursor_col = 0
	case 'G': // CHA — cursor horizontal absolute (1-based)
		grid_move_cursor(g)
		g.cursor_col = clamp(csi_param(csi, 0, 1) - 1, 0, g.cols - 1)
	case 'd': // VPA — vertical position absolute (1-based)
		grid_move_cursor(g)
		g.cursor_row = clamp(csi_param(csi, 0, 1) - 1, 0, g.rows - 1)
	case 'H', 'f': // CUP/HVP — cursor position (1-based row;col)
		grid_move_cursor(g)
		row := csi_param(csi, 0, 1)
		col := csi_param(csi, 1, 1)
		g.cursor_row = clamp(row - 1, 0, g.rows - 1)
		g.cursor_col = clamp(col - 1, 0, g.cols - 1)
	case 'J': // ED — erase in display
		grid_erase_display(g, csi_param(csi, 0, 0))
	case 'K': // EL — erase in line
		grid_erase_line(g, csi_param(csi, 0, 0))
	case 'L': // IL — insert lines
		grid_insert_lines(g, csi_count(csi, 0))
	case 'M': // DL — delete lines
		grid_delete_lines(g, csi_count(csi, 0))
	case '@': // ICH — insert blank characters
		grid_insert_chars(g, csi_count(csi, 0))
	case 'P': // DCH — delete characters
		grid_delete_chars(g, csi_count(csi, 0))
	case 'X': // ECH — erase characters (bce)
		grid_erase_chars(g, csi_count(csi, 0))
	case 'S': // SU — scroll up
		for _ in 0 ..< csi_count(csi, 0) {
			grid_scroll_up(g)
		}
	case 'T': // SD — scroll down
		for _ in 0 ..< csi_count(csi, 0) {
			grid_scroll_down(g)
		}
	case 'r': // DECSTBM — set scrolling region (1-based top;bottom)
		grid_set_scroll_region(g, csi_param(csi, 0, 1), csi_param(csi, 1, g.rows))
	case 'h', 'l': // SM/RM — set/reset mode (DEC private via CSI ? ...)
		if csi.private {
			set := csi.final == 'h'
			switch csi_param(csi, 0, 0) {
			case 1: // DECCKM — application cursor keys
				g.application_cursor = set
			case 25: // DECTCEM — show/hide the terminal cursor
				g.cursor_visible = set
			case 1000: // DECSET 1000 — button-event tracking
				g.mouse_reporting = set
			case 1006: // DECSET 1006 — SGR mouse encoding
				g.mouse_sgr = set
			case 1049: // alternate screen buffer
				grid_switch_alternate(g, set)
			}
		}
	case:
		// Unrecognized or unsupported CSI is ignored deterministically.
	}
}

grid_erase_line :: proc(g: ^Grid, mode: int) {
	row := g.cursor_row
	switch mode {
	case 0: // cursor to end of line
		for col in g.cursor_col ..< g.cols {
			cell_ptr(g, row, col)^ = Cell{r = 0, style = g.style, link = -1}
		}
	case 1: // start of line to cursor
		for col in 0 ..= min(g.cursor_col, g.cols - 1) {
			cell_ptr(g, row, col)^ = Cell{r = 0, style = g.style, link = -1}
		}
	case 2: // whole line
		grid_fill_row(g, row, g.style)
	}
}

grid_erase_display :: proc(g: ^Grid, mode: int) {
	switch mode {
	case 0: // cursor to end of screen
		grid_erase_line(g, 0)
		for row in g.cursor_row + 1 ..< g.rows {
			grid_fill_row(g, row, g.style)
		}
	case 1: // start of screen to cursor
		grid_erase_line(g, 1)
		for row in 0 ..< g.cursor_row {
			grid_fill_row(g, row, g.style)
		}
	case 2: // whole screen
		for row in 0 ..< g.rows {
			grid_fill_row(g, row, g.style)
		}
	case 3: // clear scrollback (xterm extension)
		for line in g.scrollback {
			line_destroy(line, g.allocator)
		}
		resize(&g.scrollback, 0)
	}
}

// grid_fill_row fills one row with blank cells carrying `style`. Erase
// operations (bce — background color erase) pass the current style so the
// background survives an erase; scrolling passes the default style so a
// newly-scrolled blank line has no background.
grid_fill_row :: proc(g: ^Grid, row: int, style: Style) {
	for col in 0 ..< g.cols {
		cell_ptr(g, row, col)^ = Cell{r = 0, style = style, link = -1}
	}
}

// grid_clear_row clears a row to the default style (no background). Used by
// scrolling, which must not carry the current SGR background into the new line.
grid_clear_row :: proc(g: ^Grid, row: int) {
	grid_fill_row(g, row, Style{})
}

// grid_erase_chars erases n cells at the cursor, filling them with the current
// background (ECH, CSI X). The cursor does not move.
grid_erase_chars :: proc(g: ^Grid, n: int) {
	row := g.cursor_row
	for col in g.cursor_col ..< min(g.cursor_col + n, g.cols) {
		cell_ptr(g, row, col)^ = Cell{r = 0, style = g.style, link = -1}
	}
}

// grid_set_scroll_region applies DECSTBM (CSI top;bottom r), 1-based and
// inclusive. A missing or zero top is 1; a missing or oversized bottom is the
// last row. An inverted region resets to the full screen. DECSTBM moves the
// cursor to the home position.
grid_set_scroll_region :: proc(g: ^Grid, top, bottom: int) {
	t := top
	b := bottom
	if t < 1 {
		t = 1
	}
	if b < 1 || b > g.rows {
		b = g.rows
	}
	if b < t {
		t = 1
		b = g.rows
	}
	g.scroll_top = t - 1
	g.scroll_bottom = b - 1
	g.cursor_row = 0
	g.cursor_col = 0
	g.wrap_pending = false
}

// grid_insert_lines inserts n blank lines at the cursor row, shifting rows down
// within the scrolling region. The cursor must be inside the region.
grid_insert_lines :: proc(g: ^Grid, n: int) {
	top := g.scroll_top
	bottom := g.scroll_bottom
	row := g.cursor_row
	if row < top || row > bottom {
		return
	}
	for _ in 0 ..< n {
		for r := bottom; r > row; r -= 1 {
			copy(g.cells[r * g.cols:(r + 1) * g.cols], g.cells[(r - 1) * g.cols:r * g.cols])
		}
		grid_fill_row(g, row, g.style)
	}
}

// grid_delete_lines deletes n lines at the cursor row, shifting rows up within
// the scrolling region and leaving blank lines at its bottom. The cursor must
// be inside the region.
grid_delete_lines :: proc(g: ^Grid, n: int) {
	top := g.scroll_top
	bottom := g.scroll_bottom
	row := g.cursor_row
	if row < top || row > bottom {
		return
	}
	for _ in 0 ..< n {
		for r := row; r < bottom; r += 1 {
			copy(g.cells[r * g.cols:(r + 1) * g.cols], g.cells[(r + 1) * g.cols:(r + 2) * g.cols])
		}
		grid_fill_row(g, bottom, g.style)
	}
}

grid_insert_chars :: proc(g: ^Grid, n: int) {
	row := g.cursor_row
	for _ in 0 ..< n {
		for col := g.cols - 1; col > g.cursor_col; col -= 1 {
			cell_ptr(g, row, col)^ = cell_at(g, row, col - 1)
		}
		cell_ptr(g, row, g.cursor_col)^ = Cell{r = 0, style = g.style, link = -1}
	}
}

grid_delete_chars :: proc(g: ^Grid, n: int) {
	row := g.cursor_row
	for _ in 0 ..< n {
		for col := g.cursor_col; col < g.cols - 1; col += 1 {
			cell_ptr(g, row, col)^ = cell_at(g, row, col + 1)
		}
		cell_ptr(g, row, g.cols - 1)^ = Cell{r = 0, style = g.style, link = -1}
	}
}

// grid_scroll_up moves the scrolling region up one row. A full-screen region
// pushes the top row into scrollback; a partial region drops it.
grid_scroll_up :: proc(g: ^Grid) {
	top := g.scroll_top
	bottom := g.scroll_bottom
	if top == 0 && bottom == g.rows - 1 {
		line := grid_row_line(g, 0)
		append(&g.scrollback, line)
		if len(g.scrollback) > g.max_scrollback {
			line_destroy(g.scrollback[0], g.allocator)
			ordered_remove(&g.scrollback, 0)
		}
	}
	for row := top; row < bottom; row += 1 {
		copy(g.cells[row * g.cols:(row + 1) * g.cols], g.cells[(row + 1) * g.cols:(row + 2) * g.cols])
	}
	grid_clear_row(g, bottom)
}

// grid_scroll_down moves the scrolling region down one row, clearing its top
// row and dropping its bottom row.
grid_scroll_down :: proc(g: ^Grid) {
	top := g.scroll_top
	bottom := g.scroll_bottom
	for row := bottom; row > top; row -= 1 {
		copy(g.cells[row * g.cols:(row + 1) * g.cols], g.cells[(row - 1) * g.cols:row * g.cols])
	}
	grid_clear_row(g, top)
}

// grid_row_line builds a scrollback Line (text only) from a screen row, with
// trailing empty cells trimmed.
grid_row_line :: proc(g: ^Grid, row: int) -> Line {
	return grid_row_line_stride(g, row, g.cols)
}

// grid_row_line_stride is grid_row_line with an explicit column stride. The
// returned Line carries coalesced style runs (one Run per contiguous cell
// range sharing a style), so scrollback lines keep their colors.
grid_row_line_stride :: proc(g: ^Grid, row, cols: int) -> Line {
	last := grid_row_last_col_stride(g, row, cols)
	if last < 0 {
		return Line{}
	}
	text := make([]rune, last + 1, g.allocator)
	runs := make([dynamic]Run, g.allocator)
	for col in 0 ..= last {
		cell := cell_at_stride(g, row, col, cols)
		r := cell.r
		if r == 0 {
			r = ' '
		}
		text[col] = r
		if len(runs) > 0 && style_equal(runs[len(runs) - 1].style, cell.style) {
			runs[len(runs) - 1].length += 1
		} else {
			append(&runs, Run{length = 1, style = cell.style})
		}
	}
	return Line{text = text, runs = runs[:]}
}

// grid_row_last_col returns the index of the last non-empty cell in row, or -1.
grid_row_last_col :: proc(g: ^Grid, row: int) -> int {
	return grid_row_last_col_stride(g, row, g.cols)
}

// grid_row_last_col_stride is grid_row_last_col with an explicit column stride.
// A cell counts as content if it has a rune or a non-default background, so an
// erased-but-colored trailing region still renders its background fill.
grid_row_last_col_stride :: proc(g: ^Grid, row, cols: int) -> int {
	for col := cols - 1; col >= 0; col -= 1 {
		cell := cell_at_stride(g, row, col, cols)
		if cell.r != 0 || cell.style.bg.kind != .Default {
			return col
		}
	}
	return -1
}

// grid_last_non_empty_row returns the last row with any non-empty cell, or -1
// when the whole screen is empty.
grid_last_non_empty_row :: proc(g: ^Grid) -> int {
	return grid_last_non_empty_row_stride(g, g.rows, g.cols)
}

// grid_last_non_empty_row_stride is grid_last_non_empty_row with an explicit
// row count and column stride (for reflow snapshots taken at the old size).
grid_last_non_empty_row_stride :: proc(g: ^Grid, rows, cols: int) -> int {
	for row := rows - 1; row >= 0; row -= 1 {
		if grid_row_last_col_stride(g, row, cols) >= 0 {
			return row
		}
	}
	return -1
}

// grid_append_row_text appends one screen row's text (empty cells become
// spaces, trailing empties trimmed) to out, without a trailing newline.
grid_append_row_text :: proc(g: ^Grid, out: ^[dynamic]byte, row: int) {
	last := grid_row_last_col(g, row)
	if last < 0 {
		return
	}
	for col in 0 ..= last {
		r := cell_at(g, row, col).r
		if r == 0 {
			r = ' '
		}
		buf: [4]byte
		n := encode_utf8(r, buf[:])
		append(out, ..buf[:n])
	}
}
