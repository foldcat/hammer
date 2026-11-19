package process_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import errs "hammer:core/errs"
import process "hammer:core/process"

when ODIN_OS == .Windows {
	HELPER :: #directory + "/../../../build/process_test_helper.exe"
} else {
	HELPER :: #directory + "/../../../build/process_test_helper"
}

expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	description := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected error: %s", description)
	delete(description, context.allocator)
	owned := err
	errs.destroy(&owned)
	return false
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	if err.kind != kind {
		description := errs.describe(err, context.allocator)
		testing.expectf(t, false, "got %v, want %v: %s", err.kind, kind, description)
		delete(description, context.allocator)
	}
	owned := err
	errs.destroy(&owned)
}

cleanup :: proc(t: ^testing.T, handle: ^process.Handle) {
	if handle.process != 0 {
		_, err := process.wait(handle, context.allocator)
		expect_ok(t, err)
	}
	if handle.process == 0 {
		expect_ok(t, process.destroy(handle, context.allocator))
		expect_ok(t, process.destroy(handle, context.allocator))
	}
}

read_exact :: proc(t: ^testing.T, pipe: ^process.Pipe, expected: int) -> []byte {
	result := make([]byte, expected, context.allocator)
	total := 0
	for total < expected {
		count, ok := read_some(t, pipe, result[total:])
		if !ok || count == 0 {
			testing.expectf(t, false, "short pipe read: %d/%d", total, expected)
			break
		}
		total += count
	}
	return result[:total]
}

read_all :: proc(t: ^testing.T, pipe: ^process.Pipe) -> []byte {
	result := make([dynamic]byte, 0, 1024, context.allocator)
	buffer: [1024]byte
	for {
		count, ok := read_some(t, pipe, buffer[:])
		if count > 0 {
			if len(result) + count > 64 * 1024 {
				testing.expect(t, false, "test output exceeded 64 KiB")
				break
			}
			append(&result, ..buffer[:count])
		}
		if !ok || count == 0 {
			if !ok {
				testing.expect(t, false, "pipe read failed")
			}
			break
		}
	}
	return result[:]
}

sandbox :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp("", "hammer-process-*", context.allocator)
	if err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", err)
	}
	return directory
}

@(test)
test_spawn_routes_arguments_environment_cwd_and_exit :: proc(t: ^testing.T) {
	directory := sandbox(t)
	if directory == "" {
		return
	}
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	handle, spawn_err := process.spawn(
		{
			command = {HELPER, "report", "plain", "two words", "quote\"slash\\", "β"},
			working_dir = directory,
			environment = {"HAMMER_PROCESS_TEST=exact"},
		},
		context.allocator,
	)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	expect_ok(t, process.close_pipe(&handle.stdin, context.allocator))
	stdout := read_all(t, &handle.stdout)
	defer delete(stdout, context.allocator)
	stderr := read_all(t, &handle.stderr)
	defer delete(stderr, context.allocator)
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.code == 7 && !status.success && status.signal == 0)

	expected := fmt.aprintf(
		"arg=plain\narg=two words\narg=quote\"slash\\\narg=β\ncwd=%s\nenv=exact\npath=\n",
		directory,
		allocator = context.allocator,
	)
	defer delete(expected, context.allocator)
	testing.expectf(t, string(stdout) == expected, "stdout %q, want %q", string(stdout), expected)
	testing.expectf(t, string(stderr) == "stderr=report\n", "stderr %q", string(stderr))
}

@(test)
test_spawn_stdin_stdout_stderr_and_cleanup :: proc(t: ^testing.T) {
	handle, spawn_err := process.spawn({command = {HELPER, "echo"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	write_all(t, &handle.stdin, transmute([]byte)string("input β"))
	expect_ok(t, process.close_pipe(&handle.stdin, context.allocator))
	expect_ok(t, process.close_pipe(&handle.stdin, context.allocator))
	stdout := read_all(t, &handle.stdout)
	defer delete(stdout, context.allocator)
	stderr := read_all(t, &handle.stderr)
	defer delete(stderr, context.allocator)
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success && status.code == 0)
	testing.expect(t, string(stdout) == "stdout=input β\n")
	testing.expect(t, string(stderr) == "stderr=input β\n")
}

@(test)
test_spawn_uses_explicit_path_environment :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		path := fmt.aprintf("PATH=%s", os.dir(HELPER), allocator = context.allocator)
		defer delete(path, context.allocator)
		handle, spawn_err := process.spawn(
			{command = {os.base(HELPER), "echo"}, environment = {path}},
			context.allocator,
		)
		if !expect_ok(t, spawn_err) {
			return
		}
		defer cleanup(t, &handle)
		expect_ok(t, process.close_pipe(&handle.stdin, context.allocator))
		stdout := read_all(t, &handle.stdout)
		defer delete(stdout, context.allocator)
		stderr := read_all(t, &handle.stderr)
		defer delete(stderr, context.allocator)
		status, wait_err := process.wait(&handle, context.allocator)
		expect_ok(t, wait_err)
		testing.expect(t, status.success && string(stdout) == "stdout=\n" && string(stderr) == "stderr=\n")
	}
}

@(test)
test_spawn_failure_and_invalid_inputs_return_no_handle :: proc(t: ^testing.T) {
	directory := sandbox(t)
	if directory == "" {
		return
	}
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	missing := fmt.aprintf("%s/missing-helper", directory, allocator = context.allocator)
	defer delete(missing, context.allocator)
	handle, err := process.spawn({command = {missing}}, context.allocator)
	expect_kind(t, err, .NotFound)
	testing.expect(t, handle.process == 0 && !handle.stdin.open && !handle.stdout.open && !handle.stderr.open)

	_, err = process.spawn({}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, err = process.spawn({command = {""}}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, err = process.spawn({command = {HELPER, "bad\x00argument"}}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, err = process.spawn({command = {HELPER}, environment = {"MISSING_SEPARATOR"}}, context.allocator)
	expect_kind(t, err, .Invalid_Input)

	arguments := make([]string, process.MAX_ARGUMENTS + 1, context.allocator)
	defer delete(arguments, context.allocator)
	arguments[0] = HELPER
	_, err = process.spawn({command = arguments}, context.allocator)
	expect_kind(t, err, .Resource_Limit)

	oversized := strings.repeat("x", process.MAX_SPAWN_BYTES + 1, context.allocator)
	defer delete(oversized, context.allocator)
	_, err = process.spawn({command = {HELPER, oversized}}, context.allocator)
	expect_kind(t, err, .Resource_Limit)
}

@(test)
test_pump_flow_is_bounded_and_ordered :: proc(t: ^testing.T) {
	handle, spawn_err := process.spawn({command = {HELPER, "flood"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	input := make([]byte, 256 * 1024, context.allocator)
	defer delete(input, context.allocator)
	for _, index in input {
		input[index] = byte(index % 251)
	}
	pump: process.Pump
	init_err := process.pump_init(
		&pump,
		&handle,
		input,
		{record_capacity = 2, chunk_bytes = 64},
		context.allocator,
	)
	if !expect_ok(t, init_err) {
		return
	}
	defer expect_ok(t, process.pump_destroy(&pump))

	stdout := make([dynamic]byte, 0, 256 * 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 256 * 1024, context.allocator)
	defer delete(stderr)
	expected_stdout, stdout_builder_err := strings.builder_make(0, 256 * 1024, context.allocator)
	if stdout_builder_err != nil {
		testing.expect(t, false, "cannot allocate expected stdout")
		return
	}
	defer strings.builder_destroy(&expected_stdout)
	expected_stderr, stderr_builder_err := strings.builder_make(0, 256 * 1024, context.allocator)
	if stderr_builder_err != nil {
		testing.expect(t, false, "cannot allocate expected stderr")
		return
	}
	defer strings.builder_destroy(&expected_stderr)
	for index in 0 ..< 4096 {
		fmt.sbprintf(&expected_stdout, "O%04d:abcdefghijklmnopqrstuvwxyz\n", index)
		fmt.sbprintf(&expected_stderr, "E%04d:ABCDEFGHIJKLMNOPQRSTUVWXYZ\n", index)
	}
	fmt.sbprintf(&expected_stdout, "input=%d\n", len(input))

	stdout_end := false
	stderr_end := false
	filled_queue := false
	next_sequence := u64(0)
	for iteration in 0 ..< 200000 {
		if process.pump_drained(&pump) {
			break
		}
		expect_ok(t, process.pump_poll(&pump))
		testing.expect(t, process.pump_record_count(&pump) <= 2)
		testing.expect(t, process.pump_buffered_bytes(&pump) <= 128)
		if !filled_queue && process.pump_backpressured(&pump) {
			filled_queue = true
			for _ in 0 ..< 16 {
				expect_ok(t, process.pump_poll(&pump))
				testing.expect(t, process.pump_record_count(&pump) == 2)
				testing.expect(t, process.pump_buffered_bytes(&pump) <= 128)
			}
		}
		if record, ok := process.pump_next(&pump); ok {
			testing.expect(t, record.sequence == next_sequence)
			next_sequence += 1
			switch record.kind {
			case .Data:
				testing.expect(t, len(record.data) > 0 && len(record.data) <= 64)
				if record.stream == .Stdout {
					testing.expect(t, len(stdout) + len(record.data) <= 256 * 1024)
					append(&stdout, ..record.data)
				} else {
					testing.expect(t, record.stream == .Stderr)
					testing.expect(t, len(stderr) + len(record.data) <= 256 * 1024)
					append(&stderr, ..record.data)
				}
			case .End:
				if record.stream == .Stdout {
					stdout_end = true
				} else {
					testing.expect(t, record.stream == .Stderr)
					stderr_end = true
				}
			case .Error:
				description := errs.describe(record.err, context.allocator)
				testing.expectf(t, false, "pump stream error: %s", description)
				delete(description, context.allocator)
			}
			process.pump_release(&pump)
		}
		if iteration == 199999 {
			testing.expect(t, false, "pump did not drain within the iteration budget")
		}
	}
	testing.expect(t, filled_queue && process.pump_input_done(&pump) && process.pump_drained(&pump))
	testing.expect(t, stdout_end && stderr_end)
	testing.expect(t, next_sequence >= 3)
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success)
	testing.expect(t, string(stdout[:]) == strings.to_string(expected_stdout))
	testing.expect(t, string(stderr[:]) == strings.to_string(expected_stderr))
}

@(test)
test_pump_cancel_closes_flow_and_preserves_queued_records :: proc(t: ^testing.T) {
	handle, spawn_err := process.spawn({command = {HELPER, "wait"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	pump: process.Pump
	init_err := process.pump_init(&pump, &handle, transmute([]byte)string("unused"), {}, context.allocator)
	if !expect_ok(t, init_err) {
		return
	}
	defer expect_ok(t, process.pump_destroy(&pump))
	for iteration in 0 ..< 10000 {
		if process.pump_record_count(&pump) > 0 {
			break
		}
		expect_ok(t, process.pump_poll(&pump))
		testing.expect(t, iteration < 9999, "pump did not observe ready output")
	}
	record, ok := process.pump_next(&pump)
	testing.expect(t, ok && record.kind == .Data && record.stream == .Stdout && string(record.data) == "ready\n")
	expect_ok(t, process.pump_cancel(&pump))
	expect_ok(t, process.pump_cancel(&pump))
	testing.expect(t, process.pump_input_done(&pump))
	testing.expect(t, !handle.stdin.open && !handle.stdout.open && !handle.stderr.open)
	queued, still_queued := process.pump_next(&pump)
	testing.expect(t, still_queued && queued == record && string(queued.data) == "ready\n")
	for {
		_, more := process.pump_next(&pump)
		if !more {
			break
		}
		process.pump_release(&pump)
	}
	testing.expect(t, process.pump_drained(&pump))
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success)
}
