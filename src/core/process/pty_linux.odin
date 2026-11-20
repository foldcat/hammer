package process

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import mem_virtual "core:mem/virtual"

import errs "../errs"

Platform_Pty :: struct {}

// ioctl request codes (asm-generic/ioctls.h). TIOCGWINSZ is predefined in
// core:sys/linux; the rest are defined here.
TIOCSCTTY :: 0x540E
TIOCSWINSZ :: 0x5414
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
ONLCR :: u32(0x004)
ISIG :: u32(0x001)
ICANON :: u32(0x002)
ECHO :: u32(0x008)
ECHONL :: u32(0x040)
IEXTEN :: u32(0x8000)
CSIZE :: u32(0x030)
PARENB :: u32(0x100)
CS8 :: u32(0x030)

// Termios is the Linux x86_64/aarch64 termios layout (4 x u32 flags, c_line,
// and 19 control-character bytes).
Termios :: struct {
	iflag: u32,
	oflag: u32,
	cflag: u32,
	lflag: u32,
	line:  u8,
	cc:    [19]u8,
}

// Winsize_Raw is the Linux struct winsize for TIOCSWINSZ/TIOCGWINSZ.
Winsize_Raw :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

// ioctl_checked wraps linux.ioctl: the raw return is the syscall result, where
// a negative value encodes -errno.
ioctl_checked :: proc "contextless" (fd: linux.Fd, request: u32, arg: uintptr) -> (result: i64, errno: linux.Errno) {
	ret := linux.ioctl(fd, request, arg)
	v := i64(ret)
	if v < 0 {
		return 0, linux.Errno(-v)
	}
	return v, .NONE
}

// pty_open allocates a pseudo-terminal pair. Master: /dev/ptmx (O_NOCTTY so it
// never becomes our controlling terminal); slave: /dev/pts/<n> from TIOCGPTN.
// TIOCSPTLCK(0) — unlockpt — is required before the slave can be opened (a
// locked slave fails with EIO). grantpt is a no-op on Linux devpts and is not
// implemented (docs/notes/m00-07-pty.md).
pty_open :: proc(scratch: runtime.Allocator) -> (master, slave: linux.Fd, errno: linux.Errno) {
	master, errno = linux.open("/dev/ptmx", {.RDWR, .NOCTTY})
	if errno != .NONE {
		return 0, 0, errno
	}
	pty_num: i32
	if _, io_err := ioctl_checked(master, TIOCGPTN, uintptr(&pty_num)); io_err != .NONE {
		linux.close(master)
		return 0, 0, io_err
	}
	unlock: i32 = 0
	if _, io_err := ioctl_checked(master, TIOCSPTLCK, uintptr(&unlock)); io_err != .NONE {
		linux.close(master)
		return 0, 0, io_err
	}
	path := fmt.aprintf("/dev/pts/%d", pty_num, allocator = scratch)
	path_c, alloc_err := strings.clone_to_cstring(path, scratch)
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

termios_get :: proc(slave: linux.Fd, termios: ^Termios) -> linux.Errno {
	_, errno := ioctl_checked(slave, TCGETS, uintptr(termios))
	return errno
}

termios_set :: proc(slave: linux.Fd, termios: ^Termios) -> linux.Errno {
	_, errno := ioctl_checked(slave, TCSETS, uintptr(termios))
	return errno
}

// slave_set_echo_off clears ECHO so the line discipline does not bounce the
// parent's input back to the master.
slave_set_echo_off :: proc(slave: linux.Fd) -> bool {
	tio := Termios{}
	if errno := termios_get(slave, &tio); errno != .NONE {
		return false
	}
	tio.lflag &= ~ECHO
	return termios_set(slave, &tio) == .NONE
}

// slave_set_raw applies the cfmakeraw-equivalent state (no output post-
// processing, no canonical input, no echo, no control-character signals).
slave_set_raw :: proc(slave: linux.Fd) -> bool {
	tio := Termios{}
	if errno := termios_get(slave, &tio); errno != .NONE {
		return false
	}
	tio.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
	tio.oflag &= ~OPOST
	tio.cflag &= ~(CSIZE | PARENB)
	tio.cflag |= CS8
	tio.lflag &= ~(ISIG | ICANON | ECHO | ECHONL | IEXTEN)
	return termios_set(slave, &tio) == .NONE
}

// slave_set_terminal applies the interactive-terminal line discipline: cooked
// input (echo, canonical input, control-character signals) and output
// post-processing on (ONLCR translates the child's '\n' to "\r\n"). The tty
// echoes each keystroke back to the master, so a plain shell (sh/dash) shows
// typed text immediately; a line editor (readline) switches the slave to raw
// mode itself while it reads.
slave_set_terminal :: proc(slave: linux.Fd) -> bool {
	tio := Termios{}
	if errno := termios_get(slave, &tio); errno != .NONE {
		return false
	}
	tio.iflag |= ICRNL
	tio.oflag |= OPOST | ONLCR
	tio.lflag |= ISIG | ICANON | ECHO | ECHONL | IEXTEN
	return termios_set(slave, &tio) == .NONE
}

pty_set_winsize :: proc(master: linux.Fd, size: Winsize) -> linux.Errno {
	raw := Winsize_Raw{row = size.rows, col = size.cols}
	_, errno := ioctl_checked(master, TIOCSWINSZ, uintptr(&raw))
	return errno
}

// child_exec_pty runs in the forked child: it becomes a session leader, takes
// the slave as its controlling terminal, redirects fds 0/1/2 onto it, arms
// PR_SET_PDEATHSIG, and execs. It never returns; failures are reported on
// error_fd and exit.
child_exec_pty :: proc "contextless" (
	slave: linux.Fd,
	master: linux.Fd,
	error_fd: linux.Fd,
	exec: Spawn_Exec,
	parent_pid: linux.Pid,
) -> ! {
	if _, errno := linux.setsid(); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if _, errno := ioctl_checked(slave, TIOCSCTTY, 0); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if errno := linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGHUP), 0, 0, 0); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if linux.getppid() != parent_pid {
		child_fail(error_fd, .ESRCH)
	}
	if _, errno := linux.dup2(slave, 0); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if _, errno := linux.dup2(slave, 1); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if _, errno := linux.dup2(slave, 2); errno != .NONE {
		child_fail(error_fd, errno)
	}
	if slave > 2 {
		linux.close(slave)
	}
	linux.close(master)
	if exec.working_dir != nil {
		if errno := linux.chdir(exec.working_dir); errno != .NONE {
			child_fail(error_fd, errno)
		}
	}

	last_errno := linux.Errno.ENOENT
	for index in 0 ..< exec.executable_count {
		errno := linux.execve(exec.executables[index], exec.argv, exec.envp)
		last_errno = errno
		if errno != .ENOENT && errno != .ENOTDIR && errno != .EACCES {
			child_fail(error_fd, errno)
		}
	}
	child_fail(error_fd, last_errno)
}

platform_pty_spawn :: proc(desc: Description, options: Pty_Options, allocator := context.allocator) -> (Pty, errs.Error) {
	arena: mem_virtual.Arena
	if arena_err := mem_virtual.arena_init_growing(&arena); arena_err != .None {
		return {}, errs.newf(.Resource_Limit, "process: cannot initialize spawn arena: %v", arena_err, allocator = allocator)
	}
	defer {
		mem_virtual.arena_free_all(&arena)
		mem_virtual.arena_destroy(&arena)
	}
	scratch := mem_virtual.arena_allocator(&arena)

	exec, exec_err := build_exec(desc, scratch, allocator)
	if !errs.ok(exec_err) {
		return {}, exec_err
	}

	master, slave, errno := pty_open(scratch)
	if errno != .NONE {
		return {}, linux_error("pty allocation", errno, allocator)
	}
	defer close_raw(&master)
	defer close_raw(&slave)

	switch options.termios {
	case .Raw:
		if !slave_set_raw(slave) {
			return {}, errs.new(.IO, "process: cannot apply raw termios to pty slave", allocator = allocator)
		}
	case .Cooked:
		if !slave_set_terminal(slave) {
			return {}, errs.new(.IO, "process: cannot apply terminal termios to pty slave", allocator = allocator)
		}
	case .Sane:
		if !slave_set_echo_off(slave) {
			return {}, errs.new(.IO, "process: cannot apply termios to pty slave", allocator = allocator)
		}
	}

	if options.size.cols != 0 && options.size.rows != 0 {
		if size_errno := pty_set_winsize(master, options.size); size_errno != .NONE {
			return {}, linux_error("pty window-size setup", size_errno, allocator)
		}
	}

	error_read, error_write, pipe_errno := open_pipe()
	if pipe_errno != .NONE {
		return {}, linux_error("pty error-pipe creation", pipe_errno, allocator)
	}
	defer close_raw(&error_read)
	defer close_raw(&error_write)

	parent_pid := linux.getpid()
	pid, fork_errno := linux.fork()
	if fork_errno != .NONE {
		return {}, linux_error("fork", fork_errno, allocator)
	}
	if pid == 0 {
		close_raw(&error_read)
		child_exec_pty(slave, master, error_write, exec, parent_pid)
	}

	close_raw(&slave)
	close_raw(&error_write)
	exec_errno, read_errno := read_exec_error(error_read)
	close_raw(&error_read)
	if read_errno != .NONE {
		reap_failed_child(pid)
		return {}, linux_error("exec handshake", read_errno, allocator)
	}
	if exec_errno != .NONE {
		reap_failed_child(pid)
		return {}, linux_error("exec", exec_errno, allocator)
	}

	if nb_errno := linux.fcntl_setfl(master, .SETFL, {.NONBLOCK}); nb_errno != .NONE {
		reap_failed_child(pid)
		return {}, linux_error("nonblocking pty setup", nb_errno, allocator)
	}

	master_fd := master
	master = -1
	return Pty{
		id = Process_ID(pid),
		process = uintptr(pid),
		master = {native = uintptr(master_fd), open = true},
	}, {}
}

platform_pty_read :: proc(pty: ^Pty, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	for {
		count, errno := linux.read(linux.Fd(pty.master.native), buffer)
		if errno == .EINTR {
			continue
		}
		if errno == .EAGAIN {
			return 0, .Would_Block, {}
		}
		if errno == .EIO {
			// The slave closed: the child is gone and its output is done.
			return 0, .End, {}
		}
		if errno != .NONE {
			return 0, .Closed, linux_error("pty read", errno, allocator)
		}
		if count == 0 {
			return 0, .End, {}
		}
		return count, .Data, {}
	}
}

platform_pty_resize :: proc(pty: ^Pty, size: Winsize, allocator := context.allocator) -> errs.Error {
	if errno := pty_set_winsize(linux.Fd(pty.master.native), size); errno != .NONE {
		return linux_error("pty resize", errno, allocator)
	}
	return {}
}

platform_pty_try_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, bool, errs.Error) {
	pid := linux.Pid(pty.process)
	status: u32
	for {
		waited, errno := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return {}, false, linux_error("waitpid", errno, allocator)
		}
		if waited == 0 {
			return {}, false, {}
		}
		if waited != pid {
			return {}, false, errs.new(.IO, "process: waitpid returned an unexpected process", allocator = allocator)
		}
		pty.process = 0
		return exit_status(status), true, {}
	}
}

platform_pty_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	pid := linux.Pid(pty.process)
	status: u32
	for {
		waited, errno := linux.waitpid(pid, &status, {}, nil)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return {}, linux_error("waitpid", errno, allocator)
		}
		if waited != pid {
			return {}, errs.new(.IO, "process: waitpid returned an unexpected process", allocator = allocator)
		}
		break
	}
	pty.process = 0
	return exit_status(status), {}
}

platform_pty_stop :: proc(pty: ^Pty, force: bool, allocator := context.allocator) -> errs.Error {
	signal := linux.Signal.SIGTERM
	if force {
		signal = .SIGKILL
	}
	errno := linux.kill(-linux.Pid(pty.process), signal)
	if errno == .ESRCH {
		return {}
	}
	if errno != .NONE {
		return linux_error("pty process-group signal", errno, allocator)
	}
	return {}
}
