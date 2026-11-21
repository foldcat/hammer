package process_test

import "core:strings"
import "core:testing"
import "core:time"

import process "hammer:core/process"

cleanup_pty :: proc(t: ^testing.T, pty: ^process.Pty) {
	if pty.process != 0 {
		_, err := process.pty_wait(pty, context.allocator)
		expect_ok(t, err)
	}
	if pty.process == 0 {
		expect_ok(t, process.pty_destroy(pty, context.allocator))
		expect_ok(t, process.pty_destroy(pty, context.allocator))
	}
}

// pty_read_all drains the master until the child closes the slave (.End).
pty_read_all :: proc(t: ^testing.T, pty: ^process.Pty) -> []byte {
	result := make([dynamic]byte, 0, 1024, context.allocator)
	buffer: [1024]byte
	for _ in 0 ..< 20000 {
		count, status, err := process.pty_read(pty, buffer[:], context.allocator)
		if !expect_ok(t, err) || status == .Closed {
			break
		}
		if status == .Would_Block {
			time.sleep(time.Millisecond)
			continue
		}
		if status == .End {
			break
		}
		if count > 0 {
			if len(result) + count > 64 * 1024 {
				testing.expect(t, false, "pty output exceeded 64 KiB")
				break
			}
			append(&result, ..buffer[:count])
		}
	}
	return result[:]
}

// pty_read_until reads until the accumulated output contains marker.
pty_read_until :: proc(t: ^testing.T, pty: ^process.Pty, marker: string) -> []byte {
	result := make([dynamic]byte, 0, 1024, context.allocator)
	buffer: [256]byte
	for _ in 0 ..< 20000 {
		count, status, err := process.pty_read(pty, buffer[:], context.allocator)
		if !expect_ok(t, err) || status == .Closed {
			break
		}
		if status == .Would_Block {
			time.sleep(time.Millisecond)
			continue
		}
		if status == .End {
			break
		}
		if count > 0 {
			append(&result, ..buffer[:count])
			if strings.contains(string(result[:]), marker) {
				break
			}
		}
	}
	return result[:]
}

@(test)
test_pty_spawn_roundtrip_and_exit :: proc(t: ^testing.T) {
	pty, spawn_err := process.pty_spawn(
		{command = {HELPER, "pty"}},
		{termios = .Raw},
		context.allocator,
	)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	written, status, write_err := process.pty_write(&pty, transmute([]byte)string("ping\n"), context.allocator)
	expect_ok(t, write_err)
	testing.expect(t, status == .Data && written == len("ping\n"))
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(t, string(output) == "tty=1\necho:ping\n", "output %q", string(output))
	exit_status, wait_err := process.pty_wait(&pty, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, exit_status.success && exit_status.code == 0)
}

@(test)
test_pty_sane_mode_echo_off_and_onlcr :: proc(t: ^testing.T) {
	// Sane mode: input echo is off, so the parent's write is not bounced back;
	// output post-processing is on, so the child's '\n' arrives as "\r\n".
	pty, spawn_err := process.pty_spawn({command = {HELPER, "pty"}}, {}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	_, _, write_err := process.pty_write(&pty, transmute([]byte)string("ping\n"), context.allocator)
	expect_ok(t, write_err)
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(t, string(output) == "tty=1\r\necho:ping\r\n", "output %q", string(output))
}

@(test)
test_pty_cooked_mode_echoes_input :: proc(t: ^testing.T) {
	// Cooked mode (the interactive terminal): the tty echoes the parent's
	// write back to the master, so a plain shell shows typed text. "ping"
	// must appear twice — once from the tty echo, once from the helper's
	// "echo:ping" reply — proving the input was echoed and then delivered.
	pty, spawn_err := process.pty_spawn({command = {HELPER, "pty"}}, {termios = .Cooked}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	_, _, write_err := process.pty_write(&pty, transmute([]byte)string("ping\n"), context.allocator)
	expect_ok(t, write_err)
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(
		t,
		strings.count(string(output), "ping") == 2,
		"expected the tty to echo 'ping' once and the helper once; output %q",
		string(output),
	)
}

@(test)
test_pty_initial_window_size :: proc(t: ^testing.T) {
	pty, spawn_err := process.pty_spawn(
		{command = {HELPER, "size"}},
		{termios = .Raw, size = {cols = 120, rows = 34}},
		context.allocator,
	)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(t, string(output) == "cols=120 rows=34\n", "output %q", string(output))
	exit_status, wait_err := process.pty_wait(&pty, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, exit_status.success)
}

@(test)
test_pty_resize_reaches_child :: proc(t: ^testing.T) {
	pty, spawn_err := process.pty_spawn({command = {HELPER, "size"}}, {termios = .Raw}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	expect_ok(t, process.pty_resize(&pty, {cols = 80, rows = 24}, context.allocator))
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(t, string(output) == "cols=80 rows=24\n", "output %q", string(output))
}

@(test)
test_pty_stop_force_kills_process_group :: proc(t: ^testing.T) {
	pty, spawn_err := process.pty_spawn({command = {HELPER, "ignore"}}, {termios = .Raw}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	output := pty_read_until(t, &pty, "ready")
	testing.expect(t, strings.contains(string(output), "ready"))
	delete(output, context.allocator)
	expect_ok(t, process.pty_stop(&pty, true, context.allocator))
	exit_status, wait_err := process.pty_wait(&pty, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, exit_status.signal == 9)
}

@(test)
test_pty_missing_executable_returns_no_pty :: proc(t: ^testing.T) {
	pty, err := process.pty_spawn({command = {"/definitely/missing/hammer-pty-helper"}}, {}, context.allocator)
	expect_kind(t, err, .NotFound)
	testing.expect(t, pty.process == 0 && !pty.master.open)
}

@(test)
test_pty_inherited_environment_has_no_malformed_entries :: proc(t: ^testing.T) {
	// A nil environment inherits the parent's. Odin's os.environ appends a
	// trailing empty string; build_exec must drop it before exec, because a
	// child that sees an empty/malformed env entry can crash (Neovim's
	// environ() asserts every entry has a '=').
	pty, spawn_err := process.pty_spawn({command = {HELPER, "envcheck"}}, {termios = .Raw}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup_pty(t, &pty)
	output := pty_read_all(t, &pty)
	defer delete(output, context.allocator)
	testing.expectf(t, strings.contains(string(output), "malformed=0"), "expected no malformed env entries; output %q", string(output))
	testing.expectf(t, !strings.contains(string(output), "total=0"), "expected a nonempty environment; output %q", string(output))
}
