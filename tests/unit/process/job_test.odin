package process_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import process "hammer:core/process"

drain_job :: proc(t: ^testing.T, job: ^process.Job, stdout, stderr: ^[dynamic]byte) {
	for {
		record, ok := process.pump_next(&job.pump)
		if !ok {
			return
		}
		switch record.kind {
		case .Data:
			testing.expect(t, len(stdout^) + len(stderr^) + len(record.data) <= 64 * 1024)
			if record.stream == .Stdout {
				append(stdout, ..record.data)
			} else {
				testing.expect(t, record.stream == .Stderr)
				append(stderr, ..record.data)
			}
		case .End:
		case .Error:
			testing.expectf(t, false, "job %d stream error: %v", u64(job.id), record.err.message)
		}
		process.pump_release(&job.pump)
	}
}

poll_job_until_releasable :: proc(t: ^testing.T, service: ^process.Job_Service, id: process.Job_ID, stdout, stderr: ^[dynamic]byte) {
	for iteration in 0 ..< 10000 {
		process.job_service_poll(service, u64(iteration))
		job := process.job_find(service, id)
		if job == nil {
			testing.expect(t, false, "job disappeared before release")
			return
		}
		drain_job(t, job, stdout, stderr)
		if process.job_releasable(job) {
			return
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "job did not become releasable within the polling budget")
}

@(test)
test_job_exit_drains_output_before_release :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	input := make([]byte, len("hello β"), context.allocator)
	defer delete(input, context.allocator)
	copy(input, "hello β")
	id, start_err := process.job_start(&service, {command = {HELPER, "echo"}}, input, 42)
	expect_ok(t, start_err)
	input[0] = 'X'
	job := process.job_find(&service, id)
	testing.expect(t, id != 0 && job != nil && job.state == .Running)
	expected_command := strings.concatenate({HELPER, " echo"}, context.allocator)
	defer delete(expected_command, context.allocator)
	testing.expect(t, job.attachment == 42 && job.command == expected_command)
	testing.expect(t, process.job_service_active_count(&service) == 1)
	stdout := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	poll_job_until_releasable(t, &service, id, &stdout, &stderr)
	testing.expect(t, job.state == .Exited && job.exit_status.success && job.err.kind == .None)
	testing.expect(t, string(stdout[:]) == "stdout=hello β\n")
	testing.expect(t, string(stderr[:]) == "stderr=hello β\n")
	expect_ok(t, process.job_release(&service, id))
	expect_ok(t, process.job_release(&service, id))
	testing.expect(t, process.job_find(&service, id) == nil)
}

@(test)
test_job_stop_attachment_is_selective :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {stop_grace_ms = 20}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	first, start_err := process.job_start(&service, {command = {HELPER, "wait"}}, nil, 7)
	expect_ok(t, start_err)
	second, second_err := process.job_start(&service, {command = {HELPER, "wait"}}, nil, 8)
	expect_ok(t, second_err)
	testing.expect(t, process.job_stop_attachment(&service, 7, 100) == 1)
	testing.expect(t, process.job_stop_attachment(&service, 99, 100) == 0)
	testing.expect(t, process.job_find(&service, first).state == .CancelRequested)
	testing.expect(t, process.job_find(&service, second).state == .Running)
	stdout := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	poll_job_until_releasable(t, &service, first, &stdout, &stderr)
	testing.expect(t, process.job_find(&service, second).state == .Running)
	expect_ok(t, process.job_release(&service, first))
	stopped, stop_err := process.job_stop(&service, second, 200)
	expect_ok(t, stop_err)
	testing.expect(t, stopped)
	poll_job_until_releasable(t, &service, second, &stdout, &stderr)
}

@(test)
test_job_stop_escalates_to_forced_tree_termination :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {stop_grace_ms = 20}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	id, start_err := process.job_start(&service, {command = {HELPER, "ignore"}}, nil, 1)
	expect_ok(t, start_err)
	job := process.job_find(&service, id)
	stdout := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	for iteration in 0 ..< 1000 {
		process.job_service_poll(&service, 0)
		drain_job(t, job, &stdout, &stderr)
		if strings.contains(string(stdout[:]), "ready\n") {
			break
		}
		testing.expect(t, iteration < 999, "ignore helper did not become ready")
		time.sleep(time.Millisecond)
	}
	stopped, stop_err := process.job_stop(&service, id, 1000)
	expect_ok(t, stop_err)
	testing.expect(t, stopped && job.state == .CancelRequested)
	process.job_service_poll(&service, 1001)
	testing.expect(t, !job.force_requested && job.handle.process != 0)
	process.job_service_poll(&service, 1020)
	testing.expect(t, job.force_requested)
	poll_job_until_releasable(t, &service, id, &stdout, &stderr)
	testing.expect(t, job.state == .Exited && job.err.kind == .None)
	when ODIN_OS == .Linux {
		testing.expect(t, job.exit_status.signal == 9)
	}
}

@(test)
test_job_failed_start_and_retained_capacity_are_bounded :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	id, start_err := process.job_start(&service, {command = {"/definitely/missing/hammer-job-helper"}}, nil, 0)
	expect_ok(t, start_err)
	job := process.job_find(&service, id)
	testing.expect(t, job.state == .FailedToStart && job.err.kind == .NotFound)
	testing.expect(t, process.job_releasable(job))
	expect_ok(t, process.job_release(&service, id))

	ids: [process.MAX_JOBS]process.Job_ID
	for index in 0 ..< process.MAX_JOBS {
		retained_id, err := process.job_start(&service, {command = {"/definitely/missing/hammer-job-helper"}}, nil, 0)
		expect_ok(t, err)
		ids[index] = retained_id
	}
	_, capacity_err := process.job_start(&service, {command = {HELPER, "wait"}}, nil, 0)
	expect_kind(t, capacity_err, .Resource_Limit)
	for retained_id in ids {
		expect_ok(t, process.job_release(&service, retained_id))
	}
	testing.expect(t, process.job_service_active_count(&service) == 0)
}

@(test)
test_job_service_destroy_force_cleans_active_job :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	id, start_err := process.job_start(&service, {command = {HELPER, "ignore"}}, nil, 0)
	expect_ok(t, start_err)
	testing.expect(t, process.job_find(&service, id).state == .Running)
	expect_ok(t, process.job_service_destroy(&service))
	expect_ok(t, process.job_service_destroy(&service))
	testing.expect(t, !service.initialized && process.job_service_active_count(&service) == 0)
}

@(test)
test_job_context_discard_runs_and_drains_without_output :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	snapshot: process.Context_Snapshot
	expect_ok(t, process.context_snapshot_init(&snapshot, {}, context.allocator))
	defer process.context_snapshot_destroy(&snapshot)

	id, start_err := process.job_start_context_discard(&service, {HELPER, "echo"}, &snapshot, 5)
	expect_ok(t, start_err)
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.discard_output && !job.has_selection_pipe)

	stdout := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	poll_job_until_releasable(t, &service, id, &stdout, &stderr)
	testing.expect(t, job.state == .Exited && job.exit_status.success && job.err.kind == .None)
	testing.expect(t, string(stdout[:]) == "stdout=\n")
	testing.expect(t, string(stderr[:]) == "stderr=\n")
	expect_ok(t, process.job_release(&service, id))
}

@(test)
test_job_state_names :: proc(t: ^testing.T) {
	testing.expect(t, process.job_state_name(.Queued) == "queued")
	testing.expect(t, process.job_state_name(.Starting) == "starting")
	testing.expect(t, process.job_state_name(.Running) == "running")
	testing.expect(t, process.job_state_name(.CancelRequested) == "stopping")
	testing.expect(t, process.job_state_name(.Exited) == "exited")
	testing.expect(t, process.job_state_name(.FailedToStart) == "failed")
}

@(test)
test_job_release_removes_owned_temporary_file :: proc(t: ^testing.T) {
	root, temp_err := os.make_directory_temp("", "hammer-job-temp-*", context.allocator)
	testing.expectf(t, temp_err == nil, "cannot create temporary-file sandbox: %v", temp_err)
	defer delete(root, context.allocator)
	defer os.remove_all(root)
	path := fmt.tprintf("%s/program.raku", root)
	testing.expect(t, os.write_entire_file(path, "say 42") == nil)

	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	id, start_err := process.job_start(&service, {command = {"/definitely/missing/hammer-raku"}}, nil, 0)
	expect_ok(t, start_err)
	expect_ok(t, process.job_track_temporary_file(&service, id, path))
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.temporary_file == path)
	expect_kind(t, process.job_track_temporary_file(&service, id, path), .Invalid_Input)
	expect_ok(t, process.job_release(&service, id))
	testing.expect(t, !os.exists(path))
	expect_kind(t, process.job_track_temporary_file(&service, 9999, path), .Invalid_Input)
}

@(test)
test_job_context_discard_copies_stdin_snapshot :: proc(t: ^testing.T) {
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	snapshot: process.Context_Snapshot
	expect_ok(t, process.context_snapshot_init(&snapshot, {}, context.allocator))
	defer process.context_snapshot_destroy(&snapshot)
	input := make([]byte, 3, context.allocator)
	defer delete(input, context.allocator)
	copy(input, "abc")
	id, start_err := process.job_start_context_discard_input(&service, {HELPER, "echo"}, &snapshot, input, 5)
	expect_ok(t, start_err)
	input[0] = 'X'
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.discard_output && string(job.input) == "abc")
	stdout := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	poll_job_until_releasable(t, &service, id, &stdout, &stderr)
	testing.expect(t, string(stdout[:]) == "stdout=abc\n")
	expect_ok(t, process.job_release(&service, id))
}
