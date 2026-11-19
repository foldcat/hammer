package process_test

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:testing"

import process "hammer:core/process"

write_all :: proc(t: ^testing.T, pipe: ^process.Pipe, data: []byte) {
	remaining := data
	for len(remaining) > 0 {
		written, status, err := process.write_pipe(pipe, remaining, context.allocator)
		if !expect_ok(t, err) || status == .End || status == .Closed {
			testing.expect(t, false, "pipe write failed")
			return
		}
		remaining = remaining[written:]
	}
}

read_some :: proc(t: ^testing.T, pipe: ^process.Pipe, buffer: []byte) -> (int, bool) {
	for {
		count, status, err := process.read_pipe(pipe, buffer, context.allocator)
		if !expect_ok(t, err) || status == .Closed {
			return 0, false
		}
		if status == .Would_Block {
			continue
		}
		return count, true
	}
}

@(test)
test_linux_child_inherits_only_standard_pipes :: proc(t: ^testing.T) {
	directory := sandbox(t)
	if directory == "" {
		return
	}
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	marker_path := fmt.aprintf("%s/inherited-marker", directory, allocator = context.allocator)
	defer delete(marker_path, context.allocator)
	marker, open_err := os.open(marker_path, {.Write, .Create})
	if open_err != nil {
		testing.expectf(t, false, "cannot open marker: %v", open_err)
		return
	}
	defer os.close(marker)
	if errno := linux.fcntl_setfd(linux.Fd(os.fd(marker)), .SETFD, {}); errno != .NONE {
		testing.expectf(t, false, "cannot make marker inheritable: %v", errno)
		return
	}

	handle, spawn_err := process.spawn({command = {HELPER, "wait"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	ready := read_exact(t, &handle.stdout, len("ready\n"))
	testing.expect(t, string(ready) == "ready\n")
	delete(ready, context.allocator)
	group, group_err := linux.getpgid(linux.Pid(handle.process))
	testing.expect(t, group_err == .NONE && group == linux.Pid(handle.process))

	fd_path := fmt.aprintf("/proc/%d/fd", u64(handle.id), allocator = context.allocator)
	defer delete(fd_path, context.allocator)
	entries, read_err := os.read_all_directory_by_path(fd_path, context.allocator)
	if read_err != nil {
		testing.expectf(t, false, "cannot inspect child descriptors: %v", read_err)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expectf(t, len(entries) == 3, "child has %d descriptors, want stdin/stdout/stderr only", len(entries))
	for entry in entries {
		target, link_err := os.read_link(entry.fullpath, context.allocator)
		if link_err != nil {
			testing.expectf(t, false, "cannot read descriptor link: %v", link_err)
			continue
		}
		testing.expectf(t, target != marker_path, "child inherited marker descriptor: %s", target)
		delete(target, context.allocator)
	}
	expect_ok(t, process.close_pipe(&handle.stdin, context.allocator))
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success)
}

@(test)
test_failed_exec_closes_partial_pipe_sets :: proc(t: ^testing.T) {
	count_fds :: proc(t: ^testing.T) -> int {
		entries, err := os.read_all_directory_by_path("/proc/self/fd", context.allocator)
		if err != nil {
			testing.expectf(t, false, "cannot inspect test descriptors: %v", err)
			return -1
		}
		defer os.file_info_slice_delete(entries, context.allocator)
		return len(entries)
	}

	before := count_fds(t)
	for _ in 0 ..< 32 {
		handle, err := process.spawn({command = {"/definitely/missing/hammer-process-helper"}}, context.allocator)
		expect_kind(t, err, .NotFound)
		testing.expect(t, handle.process == 0 && !handle.stdin.open && !handle.stdout.open && !handle.stderr.open)
	}
	after := count_fds(t)
	testing.expectf(t, before >= 0 && after == before, "failed spawns leaked descriptors: before=%d after=%d", before, after)
}
