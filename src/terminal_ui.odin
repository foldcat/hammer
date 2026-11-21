package main

import "core:fmt"
import "core:log"
import "core:strings"

import command "core/command"
import console "core/console"
import coords "core/coords"
import errs "core/errs"
import input "core/input"
import layout "core/layout"
import process "core/process"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

// Terminal window (SPECS §12.5 model B — M10.06 slice 2 / M10.07).
//
// `Win` opens a PTY-backed shell in a dedicated buffer. The child's output is
// read from the PTY master and decoded through a terminal grid (the model-B
// console.Grid_Stream), which tracks cursor addressing, CR/backspace/erase
// progress, and scrolling; the grid is drained into the buffer's document so
// the visible screen — including a partial prompt line and echoed keystrokes —
// updates in place each frame. Typed input is forwarded to the PTY as raw
// bytes. The PTY slave runs in the cooked line discipline (echo on, output
// post-processing on), so the tty echoes each keystroke for a plain shell
// while a line editor (readline) switches the slave to raw mode itself.
//
// Alternate screen, resize (SIGWINCH), and per-run color rendering are still
// deferred (M10.08).

TERMINAL_READ_BYTES :: 4096
TERMINAL_COLS :: 80
TERMINAL_ROWS :: 24

Editor_Terminal :: struct {
	pty:         process.Pty,
	grid:        console.Grid_Stream,
	render:      [dynamic]byte, // scratch for building the transcript text
	read_buffer: [TERMINAL_READ_BYTES]u8,
	live:        bool, // child has not been reaped
	eof:         bool, // master read reached end-of-stream
	done:        bool, // pty destroyed and output finalized
	following:   bool, // view is pinned to the tail (new output scrolls to it)
	status:      process.Exit_Status,
}

// editor_command_win opens a terminal window running the configured shell.
editor_command_win :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	if invocation.argument != "" {
		return errs.new(.Invalid_Input, "terminal: Win takes no arguments", allocator = permanent())
	}
	target := editor_command_source_target(cmd_context.source)
	column_id := editor_look_column(target)
	if column_id == 0 {
		return errs.new(.NotFound, "view: no column is available for Win", allocator = permanent())
	}
	shell := cfg.Shell
	if shell == "" {
		shell = command.pipe_default_shell()
	}
	buffer, alloc_err := editor_alloc_terminal_buffer(shell)
	if !errs.ok(alloc_err) {
		return alloc_err
	}
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		return open_err
	}
	// A terminal is a fixed monospace grid: no line numbers, no soft wrap.
	item.wrap_mode = .Truncate
	item.line_numbers = false
	editor_activate_window(item.window_id)
	log.infof("terminal: opened window=%d buffer=%d shell=%q", u64(item.window_id), u64(buffer.id), shell)
	return {}
}

// editor_alloc_terminal_buffer spawns an interactive shell on a PTY and returns
// a fresh .Terminal buffer whose document receives the grid transcript.
editor_alloc_terminal_buffer :: proc(shell: string) -> (^Editor_Buffer, errs.Error) {
	if editor.next_buffer_id == 0 {
		return nil, errs.new(.Resource_Limit, "file: buffer ID space exhausted", allocator = permanent())
	}
	pty, spawn_err := process.pty_spawn(
		{command = {shell}},
		{termios = .Cooked, size = {cols = TERMINAL_COLS, rows = TERMINAL_ROWS}},
		permanent(),
	)
	if !errs.ok(spawn_err) {
		return nil, spawn_err
	}
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id != 0 {
			continue
		}
		id := view.Buffer_ID(editor.next_buffer_id)
		buffer^ = {id = id, generation = DEFAULT_BUFFER_GENERATION, kind = .Terminal}
		if err := txn.doc_init(&buffer.doc, {}, permanent()); !errs.ok(err) {
			buffer^ = {}
			editor_terminal_stop_destroy(&pty)
			return nil, err
		}
		if err := console.grid_stream_init(&buffer.terminal.grid, TERMINAL_ROWS, TERMINAL_COLS, 0, permanent()); !errs.ok(err) {
			txn.doc_destroy(&buffer.doc)
			buffer^ = {}
			editor_terminal_stop_destroy(&pty)
			return nil, err
		}
		buffer.terminal.render = make([dynamic]byte, permanent())
		name, clone_err := strings.clone(shell, permanent())
		if clone_err != nil {
			delete(buffer.terminal.render)
			console.grid_stream_destroy(&buffer.terminal.grid)
			txn.doc_destroy(&buffer.doc)
			buffer^ = {}
			editor_terminal_stop_destroy(&pty)
			return nil, errs.new(.Resource_Limit, "terminal: cannot allocate window name", allocator = permanent())
		}
		buffer.terminal.pty = pty
		buffer.terminal.live = true
		buffer.terminal.following = true
		buffer.job_name = name
		editor.next_buffer_id += 1
		editor.buffer_count += 1
		return buffer, {}
	}
	editor_terminal_stop_destroy(&pty)
	return nil, errs.new(.Resource_Limit, "file: no buffer slot is available", allocator = permanent())
}

// editor_terminal_stop_destroy force-stops, reaps, and destroys a PTY that is
// no longer needed (error path or window close). The child was started as a
// session leader, so the whole process group receives the signal.
editor_terminal_stop_destroy :: proc(pty: ^process.Pty) {
	if pty == nil {
		return
	}
	if pty.process != 0 {
		process.pty_stop(pty, true, permanent())
		_, wait_err := process.pty_wait(pty, permanent())
		if !errs.ok(wait_err) {
			editor_report(wait_err)
		}
	}
	if destroy_err := process.pty_destroy(pty, permanent()); !errs.ok(destroy_err) {
		editor_report(destroy_err)
	}
}

// editor_terminal_destroy releases the PTY, grid, and render scratch of a
// terminal buffer. Called from editor_destroy_buffer.
editor_terminal_destroy :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	if !t.done {
		editor_terminal_stop_destroy(&t.pty)
		t.done = true
	}
	delete(t.render)
	console.grid_stream_destroy(&t.grid)
}

// editor_poll_terminals drains PTY output and finalizes exited terminals. It is
// called once per frame.
editor_poll_terminals :: proc() {
	for index in 0 ..< view.MAX_VIEWS {
		buffer := &editor.buffers[index]
		if buffer.id == 0 || buffer.kind != .Terminal {
			continue
		}
		editor_poll_terminal(buffer)
	}
}

editor_poll_terminal :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	if t.done {
		return
	}
	// Match the grid to the window's text area and notify the child (SIGWINCH)
	// when the size changed.
	editor_terminal_resize_if_needed(buffer)
	// Drain available output into the terminal grid.
	if t.pty.master.open {
		for {
			count, status, read_err := process.pty_read(&t.pty, t.read_buffer[:], permanent())
			if !errs.ok(read_err) {
				editor_report(read_err)
				break
			}
			if status == .Data && count > 0 {
				if feed_err := console.grid_stream_feed(&t.grid, t.read_buffer[:count]); !errs.ok(feed_err) {
					editor_report(feed_err)
				}
				continue
			}
			if status == .End || status == .Closed {
				t.eof = true
			}
			break
		}
	}
	editor_terminal_sync(buffer)
	// Reap the child without blocking.
	if t.live {
		status, exited, wait_err := process.pty_try_wait(&t.pty, permanent())
		if !errs.ok(wait_err) {
			editor_report(wait_err)
		}
		if exited {
			t.live = false
			t.status = status
		}
	}
	// Finalize once the child is reaped and its output is fully drained.
	if !t.live && !t.done && (t.eof || !t.pty.master.open) {
		editor_terminal_finalize(buffer)
	}
}

editor_terminal_finalize :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	t.done = true
	editor_terminal_sync(buffer)

	marker := fmt.aprintf("\r\n[exited: %d]\r\n", t.status.code, allocator = context.temp_allocator)
	defer delete(marker, context.temp_allocator)
	console.grid_stream_feed(&t.grid, transmute([]byte)marker)
	editor_terminal_sync(buffer)

	if destroy_err := process.pty_destroy(&t.pty, permanent()); !errs.ok(destroy_err) {
		editor_report(destroy_err)
	}
	editor_refresh_window_tags()
	log.infof(
		"terminal: exited buffer=%d code=%d signal=%d bytes=%d",
		u64(buffer.id),
		t.status.code,
		t.status.signal,
		rope.tree_byte_count(&buffer.doc.tree),
	)
}

// editor_terminal_sync drains the terminal grid into the buffer document when
// it changed, replacing the transcript and following the tail if the view was
// already at the end.
editor_terminal_sync :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	if !console.grid_dirty(&t.grid.grid) {
		return
	}
	console.grid_clear_dirty(&t.grid.grid)

	item := editor_first_view_for_buffer(buffer.id)
	follow := t.following

	resize(&t.render, 0)
	console.grid_append_text(&t.grid.grid, &t.render)

	doc := &buffer.doc
	total := rope.tree_byte_count(&doc.tree)
	transaction := txn.Transaction{
		source = .Command_Output,
		base_revision = txn.doc_revision(doc),
		ops = []txn.Operation{txn.Replace{range = {0, total}, data = t.render[:]}},
		after_selection = {anchor = len(t.render), active = len(t.render), affinity = .Left},
	}
	if err := txn.doc_apply(doc, &transaction, permanent()); !errs.ok(err) {
		editor_report(err)
		return
	}
	txn.doc_collapse_history(doc)

	if item != nil {
		new_end := rope.tree_byte_count(&doc.tree)
		if follow {
			item.selection = {anchor = new_end, active = new_end, affinity = .Left}
			editor_terminal_reveal_tail(item, doc)
		} else {
			item.selection.anchor = clamp(item.selection.anchor, 0, new_end)
			item.selection.active = clamp(item.selection.active, 0, new_end)
		}
		line_count := rope.tree_line_count(&doc.tree)
		item.first_line = clamp(item.first_line, 0, rope.Line_Index(max(0, line_count - 1)))
	}
}

// editor_terminal_reveal_tail scrolls the view so the last line (the shell's
// current line, where typing happens) is visible at the bottom. Called only
// when the view was already following the tail, so a user scrolled up to read
// earlier output is not yanked back down.
editor_terminal_reveal_tail :: proc(item: ^view.View, doc: ^txn.Doc) {
	if item == nil || doc == nil {
		return
	}
	geometry, _, ok := current_layout()
	if !ok {
		return
	}
	win, found := window_for_id(&geometry, item.window_id)
	if !found {
		return
	}
	_, _, text := editor_body_parts(item, doc, win.body)
	visible := editor_visible_rows(text)
	line_count := rope.tree_line_count(&doc.tree)
	item.first_line = rope.Line_Index(max(0, line_count - visible))
	item.first_row = 0
	item.wheel_remainder = 0
}

// editor_terminal_resize_if_needed reflows the terminal grid and notifies the
// child (SIGWINCH on Unix) when the window's text area no longer matches the
// grid's rows×cols. It runs once per frame for live terminals. Cell dimensions
// are derived from the body font, matching the grid's monospace assumption.
editor_terminal_resize_if_needed :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	item := editor_first_view_for_buffer(buffer.id)
	if item == nil {
		return
	}
	geometry, _, ok := current_layout()
	if !ok {
		return
	}
	win, found := window_for_id(&geometry, item.window_id)
	if !found {
		return
	}
	_, _, text := editor_body_parts(item, &buffer.doc, win.body)
	line_height := coords.points_to_logical_px(state.dpi.points) * cfg.Line_Height
	cell_width := text_measure_advance("M")
	if line_height <= 0 || cell_width <= 0 || text.width <= 0 || text.height <= 0 {
		return
	}
	cols := clamp(int(text.width / cell_width), 1, console.MAX_GRID_COLS)
	rows := clamp(int(text.height / line_height), 1, console.MAX_GRID_ROWS)
	if cols == console.grid_cols(&t.grid.grid) && rows == console.grid_rows(&t.grid.grid) {
		return
	}
	console.grid_resize(&t.grid.grid, rows, cols)
	if resize_err := process.pty_resize(
		&t.pty,
		{cols = u16(cols), rows = u16(rows)},
		permanent(),
	); !errs.ok(resize_err) {
		editor_report(resize_err)
	} else {
		log.infof("terminal: resize buffer=%d cols=%d rows=%d", u64(buffer.id), cols, rows)
	}
}

// editor_terminal_sync_follow updates the terminal's tail-following flag from
// whether the bottom line is currently visible. The flag is what keeps new
// output pinned to the tail (editor_terminal_sync) versus letting the user
// read earlier scrollback undisturbed.
editor_terminal_sync_follow :: proc(buffer: ^Editor_Buffer, item: ^view.View, text_rect: layout.Rect) {
	if buffer == nil || item == nil {
		return
	}
	doc := &buffer.doc
	visible := editor_visible_rows(text_rect)
	line_count := rope.tree_line_count(&doc.tree)
	buffer.terminal.following = int(item.first_line) + visible >= line_count
}

// editor_terminal_scrollback scrolls a live terminal's view by one screen
// (up=true scrolls into older scrollback, up=false toward the tail) and
// updates the follow flag. It returns true when the event was consumed as
// navigation rather than forwarded to the child.
editor_terminal_scrollback :: proc(buffer: ^Editor_Buffer, up: bool) -> bool {
	item := editor_first_view_for_buffer(buffer.id)
	if item == nil {
		return false
	}
	geometry, _, ok := current_layout()
	if !ok {
		return false
	}
	win, found := window_for_id(&geometry, item.window_id)
	if !found {
		return false
	}
	_, _, text := editor_body_parts(item, &buffer.doc, win.body)
	delta := editor_visible_rows(text)
	if up {
		delta = -delta
	}
	editor_scroll_visual_rows(item, &buffer.doc, text, delta)
	editor_terminal_sync_follow(buffer, item, text)
	return true
}

// editor_active_terminal reports whether the active body is a live terminal.
editor_active_terminal :: proc() -> bool {
	if editor.active_text_kind != .Body {
		return false
	}
	buffer := editor.buffer
	return buffer != nil && buffer.kind == .Terminal && buffer.terminal.live
}

// editor_terminal_input forwards an input event to the active terminal. It
// returns true when the event was consumed and should not fall through to
// ordinary editing. Only the active body of a live terminal is forwarded;
// tag editing and non-terminal targets fall through.
editor_terminal_input :: proc(event: input.Event) -> bool {
	if !editor_active_terminal() {
		return false
	}
	buffer := editor.buffer
	t := &buffer.terminal
	#partial switch e in event {
	case input.Text:
		// The backend emits a CHAR event for Enter/Tab/Backspace in addition
		// to their Key_Down event, which already forwarded the right byte.
		// Drop the duplicate control characters so each keypress reaches the
		// PTY exactly once (a doubled '\r' makes the shell run an empty
		// command and reprint its prompt).
		if e.text == '\r' || e.text == '\n' || e.text == '\t' || e.text == '\b' {
			return true
		}
		editor_terminal_write_rune(t, e.text)
	case input.Commit_Text:
		// The IME commits Enter/Tab/Backspace as a Commit_Text in addition to
		// the Key_Down event, which already forwarded the right byte. Drop the
		// duplicate control character so each keypress reaches the PTY exactly
		// once (a doubled '\r' makes the shell run an empty command and reprint
		// its prompt).
		if e.text == "\r" || e.text == "\n" || e.text == "\t" || e.text == "\b" {
			return true
		}
		editor_terminal_write_bytes(t, transmute([]byte)e.text)
	case input.Key_Down:
		// Ctrl+Shift+C copies the terminal's selection (the terminal
		// convention) instead of sending a control byte to the shell.
		if e.key == .C && e.modifiers == {.Ctrl, .Shift} {
			editor_copy_selection()
			return true
		}
		// Shift+PageUp/PageDown navigate the scrollback without reaching the
		// shell, so a user can read earlier output while the shell stays live.
		if .Shift in e.modifiers {
			#partial switch e.key {
			case .Page_Up:
				editor_terminal_scrollback(buffer, true)
				return true
			case .Page_Down:
				editor_terminal_scrollback(buffer, false)
				return true
			}
		}
		editor_terminal_write_key(t, e.key, e.modifiers)
	case input.Key_Up:
		// Consumed; key releases carry nothing to forward.
	case:
		return false
	}
	return true
}

editor_terminal_write_rune :: proc(t: ^Editor_Terminal, r: rune) {
	if r == '\r' || r == '\n' {
		editor_terminal_write_bytes(t, []byte{'\r'})
		return
	}
	buffer: [4]byte
	count := terminal_encode_rune(r, buffer[:])
	editor_terminal_write_bytes(t, buffer[:count])
}

editor_terminal_write_key :: proc(t: ^Editor_Terminal, key: input.Key, modifiers: input.Modifiers) {
	if .Ctrl in modifiers {
		if key >= input.Key.A && key <= input.Key.Z {
			editor_terminal_write_bytes(t, []byte{u8(int(key) - int(input.Key.A) + 1)})
			return
		}
		if key == input.Key.Space {
			editor_terminal_write_bytes(t, []byte{0})
			return
		}
	}
	#partial switch key {
	case .Enter, .KP_Enter:
		editor_terminal_write_bytes(t, []byte{'\r'})
	case .Backspace:
		editor_terminal_write_bytes(t, []byte{0x7f})
	case .Tab:
		editor_terminal_write_bytes(t, []byte{'\t'})
	case .Up:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'A'})
	case .Down:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'B'})
	case .Right:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'C'})
	case .Left:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'D'})
	case .Home:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'H'})
	case .End:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', 'F'})
	case .Delete:
		editor_terminal_write_bytes(t, []byte{0x1b, '[', '3', '~'})
	case:
	}
}

editor_terminal_write_bytes :: proc(t: ^Editor_Terminal, data: []byte) {
	written, status, err := process.pty_write(&t.pty, data, permanent())
	if !errs.ok(err) {
		editor_report(err)
		return
	}
	if written != len(data) {
		log.debugf("terminal: partial write %d/%d (status %v)", written, len(data), status)
	}
}

// terminal_encode_rune writes the UTF-8 encoding of a valid scalar value r into
// out and returns the number of bytes written (1..4).
terminal_encode_rune :: proc(r: rune, out: []byte) -> int {
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
