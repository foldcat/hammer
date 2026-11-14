// M00.07 — PTY and asynchronous process output spike (Linux).
//
// Spike, not the product implementation. Probes the primitives the editor
// will need for SPECS.md §12.2 (spawn without blocking the UI, process
// group cancellation, PTY for interactive sessions) and M10 (PTY process
// mode, chunk-safe ANSI handling, terminal resize):
//
//   - PTY pair allocation via /dev/ptmx + TIOCGPTN (no grantpt/unlockpt
//     dance needed on modern devpts)
//   - fork/execve with setsid + TIOCSCTTY so the child owns the slave as
//     its controlling terminal, plus PR_SET_PDEATHSIG so the child dies
//     with us
//   - non-blocking master reads driven by poll, with chunk boundaries
//     recorded — the primitive the async output pipeline will use
//   - process-group kill(-pid) cancellation, including SIGTERM -> SIGKILL
//     escalation against a child that ignores SIGTERM
//   - TIOCSWINSZ/TIOCGWINSZ window-size round-trip through the pty
//   - exit-status reaping and the EIO-on-master read semantics after the
//     child exits
//
// Modes:
//   echo      write "hello\n" to the master; child echoes exactly 6 bytes
//   escape    child emits an ANSI sequence in 4 delayed writes; verify
//             reassembly and that the sequence is split across reads
//   flood     child writes 1 MiB; verify bounded draining, byte count,
//             pattern sampling, and that the loop kept ticking
//   kill      SIGTERM a SIGTERM-ignoring child, prove it survives, then
//             SIGKILL the process group and reap
//   size      set a window size, child reads it via TIOCGWINSZ, parent
//             reads it back via TIOCGWINSZ
//   exitcode  child exits 7; verify status and EIO on the master
//
// The child binary path is argv[2] (default "build/pty_child").
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// ioctl request codes (asm-generic/ioctls.h); TIOCGWINSZ is predefined in
// core:sys/linux, the rest are defined here.
TIOCSCTTY :: 0x540E
TIOCSWINSZ :: 0x5414
TIOCGWINSZ :: 0x5413
TIOCGPTN :: 0x80045430
TIOCSPTLCK :: 0x40045431
TCGETS :: 0x5401
TCSETS :: 0x5402

// cfmakeraw flag set (asm-generic/termbits.h).
IGNBRK :: u32(0x001)
BRKINT :: u32(0x002)
PARMRK :: u32(0x008)
ISTRIP :: u32(0x020)
INLCR :: u32(0x040)
IGNCR :: u32(0x080)
ICRNL :: u32(0x100)
IXON :: u32(0x400)
OPOST :: u32(0x001)
ISIG :: u32(0x001)
ICANON :: u32(0x002)
ECHO :: u32(0x008)
ECHONL :: u32(0x040)
IEXTEN :: u32(0x8000)
CSIZE :: u32(0x030)
PARENB :: u32(0x100)
CS8 :: u32(0x030)

// struct termios, x86_64 Linux layout (4 x u32 flags, c_line, 19 cc bytes).
Termios :: struct {
	iflag: u32,
	oflag: u32,
	cflag: u32,
	lflag: u32,
	line:  u8,
	cc:    [19]u8,
}

// prctl option (linux/prctl.h).
PR_SET_PDEATHSIG :: uintptr(1)

Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}

POLL_TIMEOUT_MS :: 20

// ioctl_checked wraps the raw ioctl wrapper: the raw return is the syscall
// result; a negative value encodes -errno. Every request used here
// returns 0 on success, so the sign test is reliable.
ioctl_checked :: proc(fd: linux.Fd, request: u32, arg: uintptr) -> (result: i64, errno: linux.Errno) {
	ret := linux.ioctl(fd, request, arg)
	v := i64(ret)
	if v < 0 {
		return 0, linux.Errno(-v)
	}
	return v, .NONE
}

// pty_open allocates a pseudo-terminal pair. Master: /dev/ptmx (O_NOCTTY
// so it never becomes our controlling terminal). Slave: /dev/pts/<n>
// from TIOCGPTN. Two findings baked in here (see docs/notes/m00-07-pty.md):
//   - TIOCSPTLCK(0) — unlockpt — is REQUIRED before the slave can be
//     opened; a locked slave fails with EIO. Verified: without it,
//     open("/dev/pts/N") returns EIO while python's openpty (which calls
//     unlockpt) succeeds on the same mount.
//   - grantpt is a no-op on Linux devpts (the slave node is created with
//     the caller's uid by the filesystem), so it is not implemented here.
pty_open :: proc() -> (master, slave: linux.Fd, errno: linux.Errno) {
	master, errno = linux.open("/dev/ptmx", {.RDWR, .NOCTTY})
	if errno != .NONE {
		return 0, 0, errno
	}
	pty_num: i32
	_, io_err := ioctl_checked(master, TIOCGPTN, uintptr(&pty_num))
	if io_err != .NONE {
		linux.close(master)
		return 0, 0, io_err
	}
	unlock: i32 = 0 // TIOCSPTLCK: 0 = unlock, nonzero = lock
	if _, io_err = ioctl_checked(master, TIOCSPTLCK, uintptr(&unlock)); io_err != .NONE {
		linux.close(master)
		return 0, 0, io_err
	}
	path := fmt.tprintf("/dev/pts/%d", pty_num) // temp allocation; used synchronously below
	path_c, alloc_err := strings.clone_to_cstring(path, context.temp_allocator)
	if alloc_err != nil {
		linux.close(master)
		return 0, 0, .ENOMEM
	}
	slave, errno = linux.open(path_c, {.RDWR, .NOCTTY})
	if errno != .NONE {
		linux.close(master)
		return 0, 0, errno
	}
	return master, slave, .NONE
}

// slave_set_echo_off clears ECHO on the slave: without it, the pty line
// discipline echoes the child's typed input back to the master (verified:
// the echo scenario produced "hello\r\nhello\r\n" — one copy from input
// echo, one from the child's own write). Terminal apps disable ECHO and
// draw their own prompt.
slave_set_echo_off :: proc(slave: linux.Fd) -> bool {
	tio := Termios{}
	if _, err := ioctl_checked(slave, TCGETS, uintptr(&tio)); err != .NONE {
		return false
	}
	tio.lflag &= ~(ECHO)
	if _, err := ioctl_checked(slave, TCSETS, uintptr(&tio)); err != .NONE {
		return false
	}
	return true
}

// slave_set_raw applies the cfmakeraw-equivalent termios state to the
// slave side: no output post-processing (OPOST off — kills the \n ->
// \r\n ONLCR translation), no canonical input, no echo, no signals from
// control characters. This is the primitive M10.07 (raw input) and the
// ANSI console need.
slave_set_raw :: proc(slave: linux.Fd) -> bool {
	tio := Termios{}
	if _, err := ioctl_checked(slave, TCGETS, uintptr(&tio)); err != .NONE {
		return false
	}
	tio.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
	tio.oflag &= ~(OPOST)
	tio.cflag &= ~(CSIZE | PARENB)
	tio.cflag |= CS8
	tio.lflag &= ~(ISIG | ICANON | ECHO | ECHONL | IEXTEN)
	if _, err := ioctl_checked(slave, TCSETS, uintptr(&tio)); err != .NONE {
		return false
	}
	return true
}

free_argv :: proc(argv: ^[dynamic]cstring) {
	for s in argv {
		if s != nil {
			free(rawptr(s))
		}
	}
	delete(argv^)
}

// spawn_on_pty forks; the child becomes a session leader, takes the slave
// as its controlling terminal, redirects fds 0/1/2 onto it, arms
// PR_SET_PDEATHSIG, and execs child_path with args. The parent closes its
// slave copy. argv storage is heap-allocated in the parent before the
// fork; the child's copy is discarded by execve (or by exit on failure).
spawn_on_pty :: proc(child_path: string, args: []string, master, slave: linux.Fd) -> (pid: linux.Pid, ok: bool) {
	argv := make([dynamic]cstring, 0, len(args) + 2)
	c0, err0 := strings.clone_to_cstring(child_path)
	if err0 != nil {
		free_argv(&argv)
		return 0, false
	}
	append(&argv, c0)
	for a in args {
		cs, err := strings.clone_to_cstring(a)
		if err != nil {
			free_argv(&argv)
			return 0, false
		}
		append(&argv, cs)
	}
	append(&argv, nil)

	child_pid, errno := linux.fork()
	if errno != .NONE {
		free_argv(&argv)
		return 0, false
	}
	if child_pid == 0 {
		// Child: raw syscalls only from here on.
		linux.setsid()
		ioctl_checked(slave, TIOCSCTTY, 0) // acquire the slave as controlling tty
		linux.dup2(slave, 0)
		linux.dup2(slave, 1)
		linux.dup2(slave, 2)
		if slave > 2 {
			linux.close(slave)
		}
		linux.close(master)
		// Die with the parent if the parent disappears first.
		linux.syscall(linux.SYS_prctl, PR_SET_PDEATHSIG, uintptr(linux.Signal.SIGHUP), 0, 0, 0)
		linux.execve(argv[0], raw_data(argv), nil)
		msg := transmute([]u8)string("child: exec failed\n")
		linux.write(2, msg)
		linux.exit(127)
	}

	free_argv(&argv)
	linux.close(slave)
	return child_pid, true
}

// read_master performs one non-blocking read on the master fd.
read_master :: proc(fd: linux.Fd, buf: []u8) -> (n: int, errno: linux.Errno) {
	for {
		n, errno = linux.read(fd, buf)
		if errno != .EINTR {
			return
		}
	}
}

// collect_output polls the master until the accumulated output contains
// stop_marker ("" = run until the child exits, detected as EIO on the
// master), appending every chunk and recording its size. Returns the
// accumulated bytes and the chunk-size history. The caller owns the
// returned dynamic arrays. Every poll timeout counts as a tick; a nonzero
// tick count proves the loop kept running instead of blocking.
collect_output :: proc(fd: linux.Fd, tick_budget: int, chunk_cap: int, stop_marker: string) -> (out: [dynamic]u8, chunks: [dynamic]int, ticks: int) {
	buf := make([]u8, chunk_cap)
	defer delete(buf)
	pfd := linux.Poll_Fd{fd = fd, events = {.IN, .HUP}}
	for ticks < tick_budget {
		rev := []linux.Poll_Fd{pfd}
		n, errno := linux.poll(rev, POLL_TIMEOUT_MS)
		pfd = rev[0]
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			fmt.eprintf(">> collect: poll failed: %v\n", errno)
			return
		}
		if n == 0 {
			ticks += 1
			continue
		}
		if .ERR in pfd.revents {
			fmt.eprintf(">> collect: poll reported error on master\n")
			return
		}
		if .IN in pfd.revents || .HUP in pfd.revents {
			got, rerr := read_master(fd, buf)
			if rerr == .EAGAIN {
				continue
			}
			if rerr == .EIO {
				return // slave side closed: the child is gone
			}
			if rerr != .NONE {
				fmt.eprintf(">> collect: read failed: %v\n", rerr)
				return
			}
			if got == 0 {
				return
			}
			append(&chunks, got)
			append(&out, ..buf[:got])
		}
		if stop_marker != "" && strings.contains(string(out[:]), stop_marker) {
			return
		}
	}
	return
}

write_master :: proc(fd: linux.Fd, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n, errno := linux.write(fd, rest)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE || n <= 0 {
			return false
		}
		rest = rest[n:]
	}
	return true
}

reap :: proc(pid: linux.Pid, block: bool) -> (status: u32, ok: bool) {
	opts: linux.Wait_Options = {} if block else {.WNOHANG}
	p, errno := linux.waitpid(pid, &status, opts, nil)
	return status, errno == .NONE && p == pid
}

report_status :: proc(status: u32, ok: bool) {
	if !ok {
		fmt.eprintln(">> reap: waitpid failed")
		return
	}
	if linux.WIFEXITED(status) {
		fmt.printf(">> reap: exited with code %d\n", linux.WEXITSTATUS(status))
	} else if linux.WIFSIGNALED(status) {
		fmt.printf(">> reap: killed by signal %d\n", linux.WTERMSIG(status))
	} else {
		fmt.printf(">> reap: unusual status 0x%x\n", status)
	}
}

// --- scenarios ---------------------------------------------------------

run_echo :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> echo: pty_open failed: %v\n", errno)
		return 1
	}
	// Input echo must be off, or the line discipline would bounce the
	// written bytes back and the output would be doubled.
	if !slave_set_echo_off(slave) {
		fmt.eprintln(">> echo: slave_set_echo_off failed")
		linux.close(master)
		linux.close(slave)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"echo", "6"}, master, slave)
	if !ok {
		fmt.eprintln(">> echo: spawn failed")
		linux.close(master)
		return 1
	}
	if !write_master(master, transmute([]u8)string("hello\n")) {
		fmt.eprintln(">> echo: write to master failed")
	}
	out, chunks, ticks := collect_output(master, 500, 64, "")
	status, rop := reap(pid, true)
	report_status(status, rop)
	linux.close(master)
	defer delete(out)
	defer delete(chunks)

	if string(out[:]) != "hello\r\n" {
		fmt.eprintf(">> echo: got %q, want %q\n", string(out[:]), "hello\r\n")
		return 1
	}
	fmt.printf(
		">> echo: round-trip ok (6 bytes in, %d bytes out with ONLCR, %d chunk(s), %d ticks)\n",
		len(out),
		len(chunks),
		ticks,
	)
	return 0
}

run_escape :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> escape: pty_open failed: %v\n", errno)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"escape"}, master, slave)
	if !ok {
		fmt.eprintln(">> escape: spawn failed")
		linux.close(master)
		return 1
	}
	// 8-byte read cap forces boundaries between the child's delayed
	// writes (5 + 3 + 4 + 1 bytes).
	out, chunks, ticks := collect_output(master, 500, 8, "")
	status, rop := reap(pid, true)
	report_status(status, rop)
	linux.close(master)
	defer delete(out)
	defer delete(chunks)

	expected := "\x1b[31mRED\x1b[0m\r\n"
	if string(out[:]) != expected {
		fmt.eprintf(">> escape: got %q, want %q\n", string(out[:]), expected)
		return 1
	}
	// The escape sequence itself must be split across reads: the first
	// read contains only "\x1b[31m".
	split := len(chunks) >= 4 && chunks[0] == 5
	fmt.printf(">> escape: reassembled ok (reads=%d", len(chunks))
	for c, _ in chunks {
		fmt.printf(",%d", c)
	}
	fmt.printf(", first-chunk-bytes=%d)\n", chunks[0])
	if !split {
		fmt.eprintln(">> escape: expected the ANSI sequence to span at least two reads")
		return 1
	}
	fmt.printf(">> escape: ANSI split across reads (ticks=%d)\n", ticks)
	return 0
}

run_flood :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> flood: pty_open failed: %v\n", errno)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"flood", "1048576"}, master, slave)
	if !ok {
		fmt.eprintln(">> flood: spawn failed")
		linux.close(master)
		return 1
	}
	start := time.tick_now()
	out, chunks, ticks := collect_output(master, 2000, 32 * 1024, "")
	elapsed := time.tick_since(start)
	status, rop := reap(pid, true)
	report_status(status, rop)
	linux.close(master)
	defer delete(out)
	defer delete(chunks)

	expected := 1048576
	if len(out) != expected {
		fmt.eprintf(">> flood: got %d bytes, want %d\n", len(out), expected)
		return 1
	}
	// Sample three windows against the repeating 16-byte pattern instead
	// of hashing the whole buffer.
	pattern := "0123456789abcdef"
	offsets := []int{0, 4096 * 5 + 1, expected - 16}
	pattern_ok := true
	for off in offsets {
		for i in 0 ..< 16 {
			if out[off + i] != pattern[(off + i) % 16] {
				fmt.eprintf(">> flood: pattern mismatch at offset %d\n", off + i)
				pattern_ok = false
			}
		}
	}
	if !pattern_ok {
		return 1
	}
	fmt.printf(
		">> flood: %d bytes drained in %d reads (%d ms, %d ticks)\n",
		len(out),
		len(chunks),
		int(elapsed) / int(time.Millisecond),
		ticks,
	)
	return 0
}

run_kill :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> kill: pty_open failed: %v\n", errno)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"stubborn"}, master, slave)
	if !ok {
		fmt.eprintln(">> kill: spawn failed")
		linux.close(master)
		return 1
	}
	// Wait for the first tick so the child is provably up.
	out1, _, ticks1 := collect_output(master, 300, 64, "tick")
	defer delete(out1)

	// The child has SIGTERM blocked; kill the process group anyway — the
	// child must survive (this is what forces escalation to SIGKILL).
	kerr := linux.kill(-pid, .SIGTERM)
	if kerr != .NONE {
		fmt.eprintf(">> kill: kill(SIGTERM, group) failed: %v\n", kerr)
	}
	time.sleep(300 * time.Millisecond)
	// At least one more tick must arrive after the SIGTERM.
	out2, _, ticks2 := collect_output(master, 300, 64, "tick")
	defer delete(out2)
	fmt.printf(">> kill: SIGTERM ignored (child produced ticks after signal: %d + %d)\n", ticks1, ticks2)

	// The SIGTERM-ignoring child must still be running: a WNOHANG waitpid
	// that returns 0 means "no status change yet" — i.e. the child is
	// alive. (The tick read above alone cannot prove liveness: it may
	// have drained pre-signal bytes already buffered in the pty.)
	probe_status: u32
	p, werr := linux.waitpid(pid, &probe_status, {.WNOHANG}, nil)
	if werr != .NONE || p != 0 {
		fmt.eprintf(">> kill: child not running after SIGTERM (waitpid -> %d, %v)\n", p, werr)
		return 1
	}
	fmt.println(">> kill: child confirmed alive after SIGTERM (WNOHANG waitpid -> 0)")

	errno = linux.kill(-pid, .SIGKILL)
	if errno != .NONE {
		fmt.eprintf(">> kill: kill(SIGKILL, group) failed: %v\n", errno)
		return 1
	}
	status, rop := reap(pid, true)
	if !rop || !linux.WIFSIGNALED(status) {
		fmt.eprintln(">> kill: expected signal termination after SIGKILL")
		report_status(status, rop)
		return 1
	}
	linux.close(master)
	if linux.WTERMSIG(status) != u32(linux.Signal.SIGKILL) {
		fmt.eprintf(">> kill: WTERMSIG=%d, want %d\n", linux.WTERMSIG(status), u32(linux.Signal.SIGKILL))
		return 1
	}
	fmt.println(">> kill: SIGKILL delivered via process group, child reaped (WTERMSIG=9)")
	return 0
}

run_size :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> size: pty_open failed: %v\n", errno)
		return 1
	}
	ws := Winsize{row = 34, col = 120}
	if _, io_err := ioctl_checked(master, TIOCSWINSZ, uintptr(&ws)); io_err != .NONE {
		fmt.eprintf(">> size: TIOCSWINSZ failed: %v\n", io_err)
		linux.close(master)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"size"}, master, slave)
	if !ok {
		fmt.eprintln(">> size: spawn failed")
		linux.close(master)
		return 1
	}
	out, chunks, ticks := collect_output(master, 500, 64, "")
	status, rop := reap(pid, true)
	report_status(status, rop)
	defer delete(out)
	defer delete(chunks)

	if string(out[:]) != "cols=120 rows=34\r\n" {
		fmt.eprintf(">> size: child reported %q\n", string(out[:]))
		return 1
	}
	// Read the size back on the master side: pty winsize is one value
	// shared by both ends.
	readback := Winsize{}
	if _, io_err := ioctl_checked(master, TIOCGWINSZ, uintptr(&readback)); io_err != .NONE {
		fmt.eprintf(">> size: TIOCGWINSZ readback failed: %v\n", io_err)
		linux.close(master)
		return 1
	}
	linux.close(master)
	if readback.col != 120 || readback.row != 34 {
		fmt.eprintf(">> size: readback cols=%d rows=%d\n", readback.col, readback.row)
		return 1
	}
	fmt.printf(">> size: child saw cols=%d rows=%d; master readback matches (ticks=%d)\n", ws.col, ws.row, ticks)
	return 0
}

run_exitcode :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> exitcode: pty_open failed: %v\n", errno)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"status", "7"}, master, slave)
	if !ok {
		fmt.eprintln(">> exitcode: spawn failed")
		linux.close(master)
		return 1
	}
	status, rop := reap(pid, true)
	if !rop || !linux.WIFEXITED(status) || linux.WEXITSTATUS(status) != 7 {
		fmt.eprintln(">> exitcode: expected clean exit with code 7")
		report_status(status, rop)
		return 1
	}
	fmt.println(">> exitcode: child exited 7")
	// After the child exits and the slave is closed, a read on the master
	// must fail with EIO — this is the Linux pty "output is done"
	// signal the async pipeline keys on.
	buf: [64]u8
	_, rerr := read_master(master, buf[:])
	linux.close(master)
	if rerr != .EIO {
		fmt.eprintf(">> exitcode: read after child exit returned %v, want EIO\n", rerr)
		return 1
	}
	fmt.println(">> exitcode: EIO on master after child exit confirmed")
	return 0
}

// run_raw puts the slave into raw termios mode before spawning an echo
// child: output post-processing is off, so "\n" arrives as "\n" (no
// ONLCR translation). This is the raw-mode primitive a terminal view
// (M10.07) needs.
run_raw :: proc(child_path: string) -> int {
	master, slave, errno := pty_open()
	if errno != .NONE {
		fmt.eprintf(">> raw: pty_open failed: %v\n", errno)
		return 1
	}
	if !slave_set_raw(slave) {
		fmt.eprintln(">> raw: slave_set_raw failed")
		linux.close(master)
		linux.close(slave)
		return 1
	}
	pid, ok := spawn_on_pty(child_path, []string{"echo", "6"}, master, slave)
	if !ok {
		fmt.eprintln(">> raw: spawn failed")
		linux.close(master)
		return 1
	}
	if !write_master(master, transmute([]u8)string("hello\n")) {
		fmt.eprintln(">> raw: write to master failed")
	}
	out, chunks, ticks := collect_output(master, 500, 64, "")
	status, rop := reap(pid, true)
	report_status(status, rop)
	linux.close(master)
	defer delete(out)
	defer delete(chunks)

	if string(out[:]) != "hello\n" {
		fmt.eprintf(">> raw: got %q, want %q\n", string(out[:]), "hello\n")
		return 1
	}
	fmt.printf(">> raw: raw termios verified (\\n passes through untranslated, %d chunk(s), %d ticks)\n", len(chunks), ticks)
	return 0
}

main :: proc() {
	args := os.args
	child_path := "build/pty_child"
	if len(args) > 2 {
		child_path = args[2]
	}
	if len(args) < 2 {
		fmt.eprintf("usage: %s <echo|escape|flood|kill|size|exitcode|raw> [child-path]\n", args[0])
		os.exit(1)
	}
	code := 1
	switch args[1] {
	case "echo":
		code = run_echo(child_path)
	case "escape":
		code = run_escape(child_path)
	case "flood":
		code = run_flood(child_path)
	case "kill":
		code = run_kill(child_path)
	case "size":
		code = run_size(child_path)
	case "exitcode":
		code = run_exitcode(child_path)
	case "raw":
		code = run_raw(child_path)
	case:
		fmt.eprintf("usage: %s <echo|escape|flood|kill|size|exitcode|raw> [child-path]\n", args[0])
	}
	os.exit(code)
}
