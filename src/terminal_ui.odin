package main

import "core:fmt"
import "core:log"
import "core:strings"

import command "core/command"
import errs "core/errs"
import input "core/input"
import process "core/process"
import rope "core/rope"
import txn "core/txn"
import view "core/view"

// Terminal window (SPECS §12.5 model B, first cut — M10.06 slice 2).
//
// `Win` opens a PTY-backed shell in a dedicated buffer. The child's output is
// read from the PTY master, decoded through the console stream (ANSI consumed,
// CR/backspace/erase progress collapsed), and appended to the buffer's rope via
// the same bounded Output_Buffer used by job output windows. Typed input is
// forwarded to the PTY as raw bytes. This is a line-oriented terminal: cursor
// addressing, the alternate screen, resize, and raw input are M10.07.

TERMINAL_READ_BYTES :: 4096

Editor_Terminal :: struct {
	pty:         process.Pty,
	output:      process.Output_Buffer,
	read_buffer: [TERMINAL_READ_BYTES]u8,
	live:        bool, // child has not been reaped
	eof:         bool, // master read reached end-of-stream
	done:        bool, // pty destroyed and output finalized
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
	editor_activate_window(item.window_id)
	log.infof("terminal: opened window=%d buffer=%d shell=%q", u64(item.window_id), u64(buffer.id), shell)
	return {}
}

// editor_alloc_terminal_buffer spawns an interactive shell on a PTY and returns
// a fresh .Terminal buffer whose document receives the decoded output.
editor_alloc_terminal_buffer :: proc(shell: string) -> (^Editor_Buffer, errs.Error) {
	if editor.next_buffer_id == 0 {
		return nil, errs.new(.Resource_Limit, "file: buffer ID space exhausted", allocator = permanent())
	}
	pty, spawn_err := process.pty_spawn({command = {shell}}, {}, permanent())
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
		if err := process.output_init(&buffer.terminal.output, &buffer.doc, {}, permanent()); !errs.ok(err) {
			txn.doc_destroy(&buffer.doc)
			buffer^ = {}
			editor_terminal_stop_destroy(&pty)
			return nil, err
		}
		name, clone_err := strings.clone(shell, permanent())
		if clone_err != nil {
			process.output_destroy(&buffer.terminal.output)
			txn.doc_destroy(&buffer.doc)
			buffer^ = {}
			editor_terminal_stop_destroy(&pty)
			return nil, errs.new(.Resource_Limit, "terminal: cannot allocate window name", allocator = permanent())
		}
		buffer.terminal.pty = pty
		buffer.terminal.live = true
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

// editor_terminal_destroy releases the PTY and output buffer of a terminal
// buffer. Called from editor_destroy_buffer.
editor_terminal_destroy :: proc(buffer: ^Editor_Buffer) {
	t := &buffer.terminal
	if !t.done {
		editor_terminal_stop_destroy(&t.pty)
		t.done = true
	}
	process.output_destroy(&t.output)
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
	// Drain available output into the buffer document.
	if t.pty.master.open {
		for {
			count, status, read_err := process.pty_read(&t.pty, t.read_buffer[:], permanent())
			if !errs.ok(read_err) {
				editor_report(read_err)
				break
			}
			if status == .Data && count > 0 {
				was_dirty, follow := editor_terminal_output_snapshot(buffer)
				append_err := process.output_append(&t.output, t.read_buffer[:count])
				editor_terminal_output_apply(buffer, was_dirty, follow)
				if !errs.ok(append_err) {
					editor_report(append_err)
					break
				}
				continue
			}
			if status == .End || status == .Closed {
				t.eof = true
			}
			break
		}
	}
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
	was_dirty, follow := editor_terminal_output_snapshot(buffer)
	if finish_err := process.output_finish(&t.output); !errs.ok(finish_err) {
		editor_report(finish_err)
	}
	editor_terminal_output_apply(buffer, was_dirty, follow)

	marker := fmt.aprintf("[exited: %d]\n", t.status.code, allocator = context.temp_allocator)
	defer delete(marker, context.temp_allocator)
	if append_err := process.output_append(&t.output, transmute([]byte)marker); !errs.ok(append_err) {
		editor_report(append_err)
	}
	editor_terminal_output_apply(buffer, was_dirty, follow)

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

editor_terminal_output_snapshot :: proc(buffer: ^Editor_Buffer) -> (was_dirty, follow: bool) {
	was_dirty = txn.doc_revision(&buffer.doc) != buffer.saved_revision
	item := editor_first_view_for_buffer(buffer.id)
	if item != nil {
		end := rope.tree_byte_count(&buffer.doc.tree)
		follow = item.selection.anchor == end && item.selection.active == end
	}
	return
}

editor_terminal_output_apply :: proc(buffer: ^Editor_Buffer, was_dirty, follow: bool) {
	t := &buffer.terminal
	if !t.output.has_update {
		return
	}
	update := &t.output.update
	item := editor_first_view_for_buffer(buffer.id)
	if item == nil {
		return
	}
	view.transform_after_edit(&editor.views, 0, buffer.id, update.transaction.ops, update.end)
	if follow {
		item.selection = update.transaction.after_selection
	}
	if update.trimmed > 0 {
		line_count := rope.tree_line_count(&buffer.doc.tree)
		item.first_line = clamp(item.first_line, 0, rope.Line_Index(max(0, line_count - 1)))
	}
	if !was_dirty {
		buffer.saved_revision = txn.doc_revision(&buffer.doc)
	}
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
		editor_terminal_write_rune(t, e.text)
	case input.Commit_Text:
		editor_terminal_write_bytes(t, transmute([]byte)e.text)
	case input.Key_Down:
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
