// PTY process mode (M10.05).
//
// A pseudo-terminal gives a child a controlling terminal, so interactive
// programs (line editing, colors, cursor addressing) work where pipes would
// make them fall back to non-interactive mode. SPECS §12.2: "PTY for
// interactive sessions" (Unix) and ConPTY on Windows.
//
// The parent owns one bidirectional master endpoint (`Pty.master`) and the
// child's stdin/stdout/stderr are the slave. Output is read with `pty_read`
// (which reports end-of-stream as `.End` when the slave closes) and input is
// sent with `pty_write`. The child is spawned as a session/process-group
// leader, so `pty_stop` signals the whole tree.
package process

import errs "../errs"

// Termios_Mode selects the slave line discipline.
Termios_Mode :: enum u8 {
	// Sane turns off input echo (so the parent does not receive its own
	// writes back) but leaves output post-processing (ONLCR) on.
	Sane,
	// Raw applies the cfmakeraw-equivalent state: no echo, no output
	// post-processing, no canonical input, no control-character signals.
	Raw,
	// Cooked applies the line discipline an interactive terminal emulator
	// uses for a plain shell: cooked input (echo on, canonical input, control-
	// character signals) and output post-processing on. The tty echoes each
	// keystroke back to the master, and a line editor that needs raw input
	// (readline) switches the slave to raw mode itself while it reads.
	Cooked,
}

// Winsize is a terminal window size in columns and rows.
Winsize :: struct {
	cols: u16,
	rows: u16,
}

// Pty_Options configures a PTY child.
Pty_Options :: struct {
	termios: Termios_Mode,
	size:    Winsize, // a zero field means the default
}

// Pty is an owned pseudo-terminal with a spawned child. Keep it at one address
// and do not copy it while the child runs.
Pty :: struct {
	id:       Process_ID,
	process:  uintptr,
	master:   Pipe,
	platform: Platform_Pty,
}

// pty_spawn allocates a PTY and spawns desc's command attached to its slave.
// The returned Pty owns the master endpoint and the child process.
pty_spawn :: proc(desc: Description, options: Pty_Options = {}, allocator := context.allocator) -> (Pty, errs.Error) {
	if err := validate_description(desc, allocator); !errs.ok(err) {
		return {}, err
	}
	return platform_pty_spawn(desc, options, allocator)
}

// pty_resize sets the terminal window size, which the child observes as its
// terminal size (and via SIGWINCH on Unix).
pty_resize :: proc(pty: ^Pty, size: Winsize, allocator := context.allocator) -> errs.Error {
	if pty == nil || pty.process == 0 {
		return errs.new(.Invalid_Input, "process: pty resize requires a live pty", allocator = allocator)
	}
	return platform_pty_resize(pty, size, allocator)
}

// pty_read performs at most one nonblocking read of the master. `.End` reports
// that the child closed the slave (its output is done).
pty_read :: proc(pty: ^Pty, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	if pty == nil || !pty.master.open {
		return 0, .Closed, {}
	}
	if len(buffer) == 0 {
		return 0, .Closed, errs.new(.Invalid_Input, "process: pty read buffer must not be empty", allocator = allocator)
	}
	return platform_pty_read(pty, buffer, allocator)
}

// pty_write sends input to the child through the master.
pty_write :: proc(pty: ^Pty, data: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	if pty == nil || !pty.master.open {
		return 0, .Closed, {}
	}
	return write_pipe(&pty.master, data, allocator)
}

// pty_try_wait never blocks. exited is false while the child runs.
pty_try_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, bool, errs.Error) {
	if pty == nil || pty.process == 0 {
		return {}, false, errs.new(.Invalid_Input, "process: pty try_wait requires a live owned process", allocator = allocator)
	}
	return platform_pty_try_wait(pty, allocator)
}

// pty_wait blocks until the child exits and reaps it.
pty_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	if pty == nil || pty.process == 0 {
		return {}, errs.new(.Invalid_Input, "process: pty wait requires a live owned process", allocator = allocator)
	}
	return platform_pty_wait(pty, allocator)
}

// pty_stop signals the child's process group. force=true guarantees termination.
pty_stop :: proc(pty: ^Pty, force: bool, allocator := context.allocator) -> errs.Error {
	if pty == nil || pty.process == 0 {
		return errs.new(.Invalid_Input, "process: pty stop requires a live owned process", allocator = allocator)
	}
	return platform_pty_stop(pty, force, allocator)
}

// pty_destroy closes the master and resets the pty. The child must already be
// reaped (via pty_wait/pty_try_wait).
pty_destroy :: proc(pty: ^Pty, allocator := context.allocator) -> errs.Error {
	if pty == nil {
		return {}
	}
	assert(pty.process == 0, "process: pty_wait must reap the child before pty_destroy")
	first: errs.Error
	if pty.master.open {
		first = close_pipe(&pty.master, allocator)
	}
	pty^ = {}
	return first
}
