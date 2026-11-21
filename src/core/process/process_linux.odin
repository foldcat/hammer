package process

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sys/linux"
import mem_virtual "core:mem/virtual"

import errs "../errs"

PR_SET_PDEATHSIG :: 1
MAX_FD :: linux.Fd(0x7fffffff)

Platform_Pipe :: struct {}
Platform_Process :: struct {}

Linux_Pipes :: struct {
	stdin_read:   linux.Fd,
	stdin_write:  linux.Fd,
	stdout_read:  linux.Fd,
	stdout_write: linux.Fd,
	stderr_read:  linux.Fd,
	stderr_write: linux.Fd,
	error_read:   linux.Fd,
	error_write:  linux.Fd,
}

close_raw :: proc "contextless" (fd: ^linux.Fd) {
	if fd^ < 0 {
		return
	}
	linux.close(fd^)
	fd^ = -1
}

close_all :: proc "contextless" (pipes: ^Linux_Pipes) {
	fds := []^linux.Fd{
		&pipes.stdin_read,
		&pipes.stdin_write,
		&pipes.stdout_read,
		&pipes.stdout_write,
		&pipes.stderr_read,
		&pipes.stderr_write,
		&pipes.error_read,
		&pipes.error_write,
	}
	for fd in fds {
		close_raw(fd)
	}
}

normalize_fd :: proc(fd: linux.Fd) -> (linux.Fd, linux.Errno) {
	if fd >= 3 {
		return fd, .NONE
	}
	normalized, errno := linux.fcntl_dupfd_cloexec(fd, .DUPFD_CLOEXEC, 3)
	linux.close(fd)
	return normalized, errno
}

open_pipe :: proc() -> (read_end, write_end: linux.Fd, errno: linux.Errno) {
	read_end, write_end = -1, -1
	fds: [2]linux.Fd
	if errno = linux.pipe2(&fds, {.CLOEXEC}); errno != .NONE {
		return
	}
	read_end, write_end = fds[0], fds[1]
	read_end, errno = normalize_fd(read_end)
	if errno != .NONE {
		close_raw(&write_end)
		return
	}
	write_end, errno = normalize_fd(write_end)
	if errno != .NONE {
		close_raw(&read_end)
		return
	}
	return
}

open_all :: proc(pipes: ^Linux_Pipes) -> linux.Errno {
	pipes^ = {
		stdin_read = -1,
		stdin_write = -1,
		stdout_read = -1,
		stdout_write = -1,
		stderr_read = -1,
		stderr_write = -1,
		error_read = -1,
		error_write = -1,
	}
	errno := linux.Errno.NONE
	pipes.stdin_read, pipes.stdin_write, errno = open_pipe()
	if errno != .NONE {
		return errno
	}
	pipes.stdout_read, pipes.stdout_write, errno = open_pipe()
	if errno != .NONE {
		return errno
	}
	pipes.stderr_read, pipes.stderr_write, errno = open_pipe()
	if errno != .NONE {
		return errno
	}
	pipes.error_read, pipes.error_write, errno = open_pipe()
	return errno
}

child_fail :: proc "contextless" (error_fd: linux.Fd, errno: linux.Errno) -> ! {
	encoded := [2]u8{u8(u16(errno) & 0xff), u8(u16(errno) >> 8)}
	linux.write(error_fd, encoded[:])
	linux.exit(127)
}

child_close_others :: proc "contextless" (error_fd: linux.Fd) -> linux.Errno {
	if error_fd > 3 {
		if errno := linux.close_range(3, error_fd - 1, {}); errno != .NONE {
			return errno
		}
	}
	if error_fd < MAX_FD {
		if errno := linux.close_range(error_fd + 1, MAX_FD, {}); errno != .NONE {
			return errno
		}
	}
	return .NONE
}

child_exec :: proc "contextless" (
	pipes: ^Linux_Pipes,
	argv: [^]cstring,
	environment: [^]cstring,
	executables: [^]cstring,
	executable_count: int,
	working_dir: cstring,
	parent_pid: linux.Pid,
) -> ! {
	if errno := linux.setpgid(0, 0); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if errno := linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGHUP), 0, 0, 0); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if linux.getppid() != parent_pid {
		child_fail(pipes.error_write, .ESRCH)
	}
	if _, errno := linux.dup2(pipes.stdin_read, 0); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if _, errno := linux.dup2(pipes.stdout_write, 1); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if _, errno := linux.dup2(pipes.stderr_write, 2); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if errno := child_close_others(pipes.error_write); errno != .NONE {
		child_fail(pipes.error_write, errno)
	}
	if working_dir != nil {
		if errno := linux.chdir(working_dir); errno != .NONE {
			child_fail(pipes.error_write, errno)
		}
	}

	last_errno := linux.Errno.ENOENT
	for index in 0 ..< executable_count {
		errno := linux.execve(executables[index], argv, environment)
		last_errno = errno
		if errno != .ENOENT && errno != .ENOTDIR && errno != .EACCES {
			child_fail(pipes.error_write, errno)
		}
	}
	child_fail(pipes.error_write, last_errno)
}

// Spawn_Exec is the fully-built argv/envp/executable set for a child exec,
// allocated in the caller's spawn arena.
Spawn_Exec :: struct {
	argv:             [^]cstring,
	envp:             [^]cstring,
	executables:      [^]cstring,
	executable_count: int,
	working_dir:      cstring,
}

// build_exec resolves the environment, argument vector, working directory, and
// PATH-searched executable list for a Description. All storage is borrowed from
// `scratch`; `allocator` is used only for error messages.
build_exec :: proc(desc: Description, scratch, allocator: runtime.Allocator) -> (Spawn_Exec, errs.Error) {
	environment := desc.environment
	if environment == nil {
		inherited, env_err := os.environ(scratch)
		if env_err != nil {
			return {}, errs.newf(.Resource_Limit, "process: cannot copy environment: %v", env_err, allocator = allocator)
		}
		environment = inherited
	}

	argv, argv_err := make([]cstring, len(desc.command) + 1, scratch)
	if argv_err != nil {
		return {}, errs.new(.Resource_Limit, "process: cannot allocate argument vector", allocator = allocator)
	}
	for argument, index in desc.command {
		converted, convert_err := strings.clone_to_cstring(argument, scratch)
		if convert_err != nil {
			return {}, errs.new(.Resource_Limit, "process: cannot copy argument vector", allocator = allocator)
		}
		argv[index] = converted
	}

	// An inherited environment can carry malformed entries — e.g. Odin's
	// os.environ currently appends a trailing empty string, and a hostile
	// parent could pass a name with no '=' separator. Strict consumers
	// (Neovim's environ(), libc setenv validation) reject those, so keep only
	// well-formed "KEY=VALUE" pairs with a nonempty key.
	valid_entries := 0
	for entry in environment {
		if strings.index_byte(entry, '=') > 0 {
			valid_entries += 1
		}
	}
	envp, envp_err := make([]cstring, valid_entries + 1, scratch)
	if envp_err != nil {
		return {}, errs.new(.Resource_Limit, "process: cannot allocate environment vector", allocator = allocator)
	}
	env_index := 0
	for entry in environment {
		if strings.index_byte(entry, '=') <= 0 {
			continue
		}
		converted, convert_err := strings.clone_to_cstring(entry, scratch)
		if convert_err != nil {
			return {}, errs.new(.Resource_Limit, "process: cannot copy environment vector", allocator = allocator)
		}
		envp[env_index] = converted
		env_index += 1
	}

	working_dir: cstring
	if desc.working_dir != "" {
		converted, convert_err := strings.clone_to_cstring(desc.working_dir, scratch)
		if convert_err != nil {
			return {}, errs.new(.Resource_Limit, "process: cannot copy working directory", allocator = allocator)
		}
		working_dir = converted
	}

	path := "/bin:/usr/bin"
	for entry in environment {
		if strings.has_prefix(entry, "PATH=") {
			path = entry[len("PATH="):]
			break
		}
	}
	executable := desc.command[0]
	executable_count := 1
	paths: []string
	if strings.index_byte(executable, '/') < 0 {
		if path == "" {
			executable_count = 1
		} else {
			split, split_err := os.split_path_list(path, scratch)
			if split_err != nil {
				return {}, errs.newf(.Resource_Limit, "process: cannot split PATH: %v", split_err, allocator = allocator)
			}
			paths = split
			executable_count = len(paths)
		}
	}
	executables, executable_err := make([]cstring, executable_count, scratch)
	if executable_err != nil {
		return {}, errs.new(.Resource_Limit, "process: cannot allocate executable search", allocator = allocator)
	}
	if strings.index_byte(executable, '/') >= 0 || path == "" {
		converted, convert_err := strings.clone_to_cstring(executable, scratch)
		if convert_err != nil {
			return {}, errs.new(.Resource_Limit, "process: cannot copy executable path", allocator = allocator)
		}
		executables[0] = converted
	} else {
		for directory, index in paths {
			candidate := executable
			if directory != "" {
				joined, join_err := strings.concatenate([]string{directory, "/", executable}, scratch)
				if join_err != nil {
					return {}, errs.new(.Resource_Limit, "process: cannot copy executable search", allocator = allocator)
				}
				candidate = joined
			}
			converted, convert_err := strings.clone_to_cstring(candidate, scratch)
			if convert_err != nil {
				return {}, errs.new(.Resource_Limit, "process: cannot copy executable search", allocator = allocator)
			}
			executables[index] = converted
		}
	}

	return Spawn_Exec{
		argv = raw_data(argv),
		envp = raw_data(envp),
		executables = raw_data(executables),
		executable_count = executable_count,
		working_dir = working_dir,
	}, {}
}

linux_error :: proc(action: string, errno: linux.Errno, allocator := context.allocator) -> errs.Error {
	kind := errs.Kind.IO
	if errno == .ENOENT || errno == .ENOTDIR {
		kind = .NotFound
	} else if errno == .ENOMEM {
		kind = .Resource_Limit
	} else if errno == .ENOSYS {
		kind = .Unsupported
	}
	return errs.newf(kind, "process: %s failed: %v", action, errno, allocator = allocator)
}

read_exec_error :: proc(fd: linux.Fd) -> (linux.Errno, linux.Errno) {
	encoded: [2]u8
	total := 0
	for total < len(encoded) {
		count, errno := linux.read(fd, encoded[total:])
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return .NONE, errno
		}
		if count == 0 {
			return .NONE, .NONE
		}
		total += count
	}
	if total != len(encoded) {
		return .NONE, .EIO
	}
	return linux.Errno(u16(encoded[0]) | u16(encoded[1]) << 8), .NONE
}

reap_failed_child :: proc(pid: linux.Pid) {
	linux.kill(-pid, .SIGKILL)
	linux.kill(pid, .SIGKILL)
	status: u32
	for {
		_, errno := linux.waitpid(pid, &status, {}, nil)
		if errno != .EINTR {
			return
		}
	}
}

platform_spawn :: proc(desc: Description, allocator := context.allocator) -> (Handle, errs.Error) {
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

	pipes: Linux_Pipes
	if errno := open_all(&pipes); errno != .NONE {
		close_all(&pipes)
		return {}, linux_error("pipe creation", errno, allocator)
	}
	defer close_all(&pipes)

	parent_pid := linux.getpid()
	pid, fork_errno := linux.fork()
	if fork_errno != .NONE {
		return {}, linux_error("fork", fork_errno, allocator)
	}
	if pid == 0 {
		close_raw(&pipes.stdin_write)
		close_raw(&pipes.stdout_read)
		close_raw(&pipes.stderr_read)
		close_raw(&pipes.error_read)
		child_exec(&pipes, exec.argv, exec.envp, exec.executables, exec.executable_count, exec.working_dir, parent_pid)
	}

	close_raw(&pipes.stdin_read)
	close_raw(&pipes.stdout_write)
	close_raw(&pipes.stderr_write)
	close_raw(&pipes.error_write)
	exec_errno, read_errno := read_exec_error(pipes.error_read)
	close_raw(&pipes.error_read)
	if read_errno != .NONE {
		reap_failed_child(pid)
		return {}, linux_error("exec handshake", read_errno, allocator)
	}
	if exec_errno != .NONE {
		reap_failed_child(pid)
		return {}, linux_error("exec", exec_errno, allocator)
	}

	parent_ends := []linux.Fd{pipes.stdin_write, pipes.stdout_read, pipes.stderr_read}
	for fd in parent_ends {
		if errno := linux.fcntl_setfl(fd, .SETFL, {.NONBLOCK}); errno != .NONE {
			reap_failed_child(pid)
			return {}, linux_error("nonblocking pipe setup", errno, allocator)
		}
	}

	handle := Handle{
		id = Process_ID(pid),
		process = uintptr(pid),
		stdin = {native = uintptr(pipes.stdin_write), open = true},
		stdout = {native = uintptr(pipes.stdout_read), open = true},
		stderr = {native = uintptr(pipes.stderr_read), open = true},
	}
	pipes.stdin_write = -1
	pipes.stdout_read = -1
	pipes.stderr_read = -1
	return handle, {}
}

exit_status :: proc(status: u32) -> Exit_Status {
	result := Exit_Status{success = linux.WIFEXITED(status) && linux.WEXITSTATUS(status) == 0}
	if linux.WIFEXITED(status) {
		result.code = int(linux.WEXITSTATUS(status))
	} else if linux.WIFSIGNALED(status) {
		result.signal = int(linux.WTERMSIG(status))
	}
	return result
}

platform_try_wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, bool, errs.Error) {
	pid := linux.Pid(handle.process)
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
		handle.process = 0
		return exit_status(status), true, {}
	}
}

platform_request_stop :: proc(handle: ^Handle, force: bool, allocator := context.allocator) -> errs.Error {
	signal := linux.Signal.SIGTERM
	if force {
		signal = .SIGKILL
	}
	errno := linux.kill(-linux.Pid(handle.process), signal)
	if errno == .ESRCH {
		return {}
	}
	if errno != .NONE {
		return linux_error("process-group signal", errno, allocator)
	}
	return {}
}

platform_wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	pid := linux.Pid(handle.process)
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
	handle.process = 0
	return exit_status(status), {}
}

platform_read_pipe :: proc(pipe: ^Pipe, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	for {
		count, errno := linux.read(linux.Fd(pipe.native), buffer)
		if errno == .EINTR {
			continue
		}
		if errno == .EAGAIN {
			return 0, .Would_Block, {}
		}
		if errno != .NONE {
			return 0, .Closed, linux_error("read", errno, allocator)
		}
		if count == 0 {
			return 0, .End, {}
		}
		return count, .Data, {}
	}
}

platform_write_pipe :: proc(pipe: ^Pipe, data: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	for {
		count, errno := linux.write(linux.Fd(pipe.native), data)
		if errno == .EINTR {
			continue
		}
		if errno == .EAGAIN {
			return 0, .Would_Block, {}
		}
		if errno == .EPIPE {
			return 0, .End, {}
		}
		if errno != .NONE {
			return 0, .Closed, linux_error("write", errno, allocator)
		}
		if count <= 0 {
			return 0, .Closed, errs.new(.IO, "process: write made no progress", allocator = allocator)
		}
		return count, .Data, {}
	}
}

close_pipe :: proc(pipe: ^Pipe, allocator := context.allocator) -> errs.Error {
	if pipe == nil || !pipe.open {
		return {}
	}
	fd := linux.Fd(pipe.native)
	pipe^ = {}
	if errno := linux.close(fd); errno != .NONE {
		return linux_error("close", errno, allocator)
	}
	return {}
}
