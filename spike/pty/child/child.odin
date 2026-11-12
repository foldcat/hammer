// M00.07 PTY spike — helper child program.
//
// This program is spawned by the parent spike (spike/pty/main.odin)
// attached to the slave side of a pseudo-terminal pair as its controlling
// terminal. It speaks raw read/write syscalls so the parent has exact
// control over what arrives at the master fd and in which chunks. No
// shell is involved.
//
// Modes (argv[1]):
//   echo <n>      read exactly n bytes from stdin, write them to stdout
//   escape        emit an ANSI escape sequence split across four writes
//                 with delays between them (chunk-boundary test)
//   flood <n>     write n bytes of a repeating 16-byte pattern in
//                 4096-byte chunks
//   lines <n>     write n lines, then exit
//   size          report TIOCGWINSZ (cols/rows) read from stdout
//   status <n>    exit with code n
//   stubborn      block SIGTERM, write a tick every 100 ms forever
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:time"

TIOCGWINSZ :: 0x5413
Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}

SYS_rt_sigprocmask :: uintptr(14)
SIG_BLOCK :: uintptr(0)
// Bit SIGTERM-1 in a single-word sigset_t.
SIGTERM_MASK :: u64(1 << (u64(int(linux.Signal.SIGTERM)) - 1))

write_fd :: proc(fd: linux.Fd, data: []u8) -> bool {
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

read_fd :: proc(fd: linux.Fd, buf: []u8) -> (int, bool) {
	for {
		n, errno := linux.read(fd, buf)
		if errno == .EINTR {
			continue
		}
		return n, errno == .NONE
	}
}

usage :: proc() {
	msg := transmute([]u8)string("usage: child <echo|escape|flood|lines|size|status|stubborn> [n]\n")
	linux.write(2, msg)
	linux.exit(2)
}

mode_echo :: proc(n: int) {
	// No explicit free: the child exits via linux.exit immediately after;
	// process teardown reclaims the buffer.
	buf := make([]u8, n)
	total := 0
	for total < n {
		got, ok := read_fd(0, buf[total:])
		if !ok || got <= 0 {
			linux.exit(1)
		}
		total += got
	}
	if !write_fd(1, buf[:total]) {
		linux.exit(1)
	}
	linux.exit(0)
}

mode_escape :: proc() {
	chunks := [][]u8 {
		[]u8{0x1b, '[', '3', '1', 'm'},
		[]u8{'R', 'E', 'D'},
		[]u8{0x1b, '[', '0', 'm'},
		[]u8{'\n'},
	}
	for chunk in chunks {
		if !write_fd(1, chunk) {
			linux.exit(1)
		}
		time.sleep(50 * time.Millisecond)
	}
	linux.exit(0)
}

mode_flood :: proc(n: int) {
	pattern := "0123456789abcdef"
	// No explicit free: the child exits via linux.exit immediately after;
	// process teardown reclaims the buffer.
	chunk := make([]u8, 4096)
	for i in 0 ..< len(chunk) {
		chunk[i] = pattern[i % len(pattern)]
	}
	total := 0
	for total < n {
		count := min(len(chunk), n - total)
		if !write_fd(1, chunk[:count]) {
			linux.exit(1)
		}
		total += count
	}
	linux.exit(0)
}

mode_lines :: proc(n: int) {
	buf: [64]u8
	for i in 1 ..= n {
		// Stack buffer + bprintf: formatted without heap activity.
		line := fmt.bprintf(buf[:], "line %d\n", i)
		if !write_fd(1, transmute([]u8)line) {
			linux.exit(1)
		}
	}
	linux.exit(0)
}

mode_size :: proc() {
	ws := Winsize{}
	ret := linux.ioctl(1, TIOCGWINSZ, uintptr(&ws))
	if i64(ret) < 0 {
		msg := transmute([]u8)string("size: TIOCGWINSZ failed\n")
		linux.write(2, msg)
		linux.exit(1)
	}
	buf: [64]u8
	report := fmt.bprintf(buf[:], "cols=%d rows=%d\n", ws.col, ws.row)
	write_fd(1, transmute([]u8)report)
	linux.exit(0)
}

mode_stubborn :: proc() {
	// Block SIGTERM: the parent's SIGTERM must stay pending (undelivered)
	// so the escalation-to-SIGKILL path is exercised. SIGKILL cannot be
	// blocked, so the parent always wins in the end.
	mask := SIGTERM_MASK
	linux.syscall(SYS_rt_sigprocmask, SIG_BLOCK, uintptr(&mask), 0, 8)
	for {
		if !write_fd(1, transmute([]u8)string("tick\n")) {
			linux.exit(1)
		}
		time.sleep(100 * time.Millisecond)
	}
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		usage()
	}
	mode := args[1]
	n := 0
	if len(args) > 2 {
		parsed, ok := strconv.parse_int(args[2])
		if !ok {
			usage()
		}
		n = parsed
	}
	switch mode {
	case "echo":
		mode_echo(n)
	case "escape":
		mode_escape()
	case "flood":
		mode_flood(n)
	case "lines":
		mode_lines(n)
	case "size":
		mode_size()
	case "status":
		linux.exit(i32(n))
	case "stubborn":
		mode_stubborn()
	case:
		usage()
	}
}
