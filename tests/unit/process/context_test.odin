package process_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import process "hammer:core/process"

context_value :: proc(environment: []string, key: string) -> string {
	for entry in environment {
		separator := strings.index_byte(entry, '=')
		if separator > 0 && entry[:separator] == key {
			return entry[separator + 1:]
		}
	}
	return ""
}

context_count :: proc(environment: []string, key: string) -> int {
	count := 0
	for entry in environment {
		separator := strings.index_byte(entry, '=')
		if separator > 0 && entry[:separator] == key {
			count += 1
		}
	}
	return count
}

@(test)
test_context_snapshot_resolves_cwd_and_replaces_reserved_environment :: proc(t: ^testing.T) {
	directory := sandbox(t)
	if directory == "" {
		return
	}
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	file_path := fmt.aprintf("%s/nested/file.txt", directory, allocator = context.allocator)
	defer delete(file_path, context.allocator)
	project_root := fmt.aprintf("%s/project", directory, allocator = context.allocator)
	defer delete(project_root, context.allocator)
	instance_root := fmt.aprintf("%s/instance", directory, allocator = context.allocator)
	defer delete(instance_root, context.allocator)
	override := fmt.aprintf("%s/override", directory, allocator = context.allocator)
	defer delete(override, context.allocator)
	empty_storage := make([]string, 1, context.allocator)
	defer delete(empty_storage, context.allocator)
	exact_empty := empty_storage[:0]

	snapshot: process.Context_Snapshot
	init_err := process.context_snapshot_init(
		&snapshot,
		{
			window_id = 12,
			buffer_id = 34,
			file_path = file_path,
			address = "3,5",
			project_root = project_root,
			instance_root = instance_root,
			endpoint = "unix:/tmp/hammer-test",
			environment = {"CUSTOM=base", "ACME_FILE=stale", "PATH=/bin"},
		},
		context.allocator,
	)
	if !expect_ok(t, init_err) {
		return
	}
	testing.expect(t, snapshot.working_dir == os.dir(file_path))
	testing.expect(t, context_value(snapshot.environment, "ACME_WINDOW_ID") == "12")
	testing.expect(t, context_value(snapshot.environment, "ACME_BUFFER_ID") == "34")
	testing.expect(t, context_value(snapshot.environment, "ACME_FILE") == file_path)
	testing.expect(t, context_value(snapshot.environment, "ACME_ADDRESS") == "3,5")
	testing.expect(t, context_value(snapshot.environment, "ACME_PROJECT_ROOT") == project_root)
	testing.expect(t, context_value(snapshot.environment, "ACME_INSTANCE_ROOT") == instance_root)
	testing.expect(t, context_value(snapshot.environment, "ACME_ENDPOINT") == "unix:/tmp/hammer-test")
	testing.expect(t, context_value(snapshot.environment, "CUSTOM") == "base")
	testing.expect(t, context_value(snapshot.environment, "PATH") == "/bin")
	testing.expect(t, context_count(snapshot.environment, "ACME_FILE") == 1)
	testing.expect(t, len(snapshot.environment) == 9)
	process.context_snapshot_destroy(&snapshot)
	testing.expect(t, snapshot.environment == nil && snapshot.working_dir == "")

	override_snapshot: process.Context_Snapshot
	override_err := process.context_snapshot_init(
		&override_snapshot,
		{file_path = file_path, working_dir = override, environment = exact_empty},
		context.allocator,
	)
	expect_ok(t, override_err)
	testing.expect(t, override_snapshot.working_dir == override)
	testing.expect(t, len(override_snapshot.environment) == len(process.CONTEXT_VARIABLES))
	process.context_snapshot_destroy(&override_snapshot)

	project_snapshot: process.Context_Snapshot
	project_err := process.context_snapshot_init(
		&project_snapshot,
		{project_root = project_root, environment = exact_empty},
		context.allocator,
	)
	expect_ok(t, project_err)
	testing.expect(t, project_snapshot.working_dir == project_root)
	process.context_snapshot_destroy(&project_snapshot)

	cwd_snapshot: process.Context_Snapshot
	cwd_err := process.context_snapshot_init(&cwd_snapshot, {environment = exact_empty}, context.allocator)
	expect_ok(t, cwd_err)
	cwd, os_err := os.get_working_directory(context.allocator)
	testing.expect(t, os_err == nil && cwd_snapshot.working_dir == cwd)
	delete(cwd, context.allocator)
	process.context_snapshot_destroy(&cwd_snapshot)

	directory_snapshot: process.Context_Snapshot
	directory_err := process.context_snapshot_init(
		&directory_snapshot,
		{file_path = directory, file_is_directory = true, environment = exact_empty},
		context.allocator,
	)
	expect_ok(t, directory_err)
	testing.expect(t, directory_snapshot.working_dir == directory)
	process.context_snapshot_destroy(&directory_snapshot)

	testing.expect(t, os.set_env("HAMMER_PROCESS_CONTEXT_TEST_INHERITED", "captured") == nil)
	defer os.unset_env("HAMMER_PROCESS_CONTEXT_TEST_INHERITED")
// Inherited capture must remain independent of later snapshot destruction.
	inherited_snapshot: process.Context_Snapshot
	inherited_err := process.context_snapshot_init(&inherited_snapshot, {}, context.allocator)
	expect_ok(t, inherited_err)
	testing.expect(t, context_value(inherited_snapshot.environment, "HAMMER_PROCESS_CONTEXT_TEST_INHERITED") == "captured")
	process.context_snapshot_destroy(&inherited_snapshot)
}

@(test)
test_context_snapshot_rejects_malformed_and_oversized_input :: proc(t: ^testing.T) {
	malformed: process.Context_Snapshot
	malformed_err := process.context_snapshot_init(&malformed, {environment = {"MISSING_SEPARATOR"}}, context.allocator)
	expect_kind(t, malformed_err, .Invalid_Input)
	testing.expect(t, malformed.environment == nil && malformed.working_dir == "")

	oversized_value := strings.repeat("x", process.MAX_SPAWN_BYTES, context.allocator)
	defer delete(oversized_value, context.allocator)
	oversized_entry := strings.concatenate({"CUSTOM=", oversized_value}, context.allocator)
	defer delete(oversized_entry, context.allocator)
	oversized: process.Context_Snapshot
	oversized_err := process.context_snapshot_init(&oversized, {environment = {oversized_entry}}, context.allocator)
	expect_kind(t, oversized_err, .Resource_Limit)
	testing.expect(t, oversized.environment == nil && oversized.working_dir == "")
}

@(test)
test_job_context_snapshot_owns_real_child_environment_and_cwd :: proc(t: ^testing.T) {
	directory := sandbox(t)
	if directory == "" {
		return
	}
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	nested := fmt.aprintf("%s/nested", directory, allocator = context.allocator)
	defer delete(nested, context.allocator)
	testing.expect(t, os.make_directory_all(nested) == nil)
	file_path := fmt.aprintf("%s/file.txt", nested, allocator = context.allocator)
	defer delete(file_path, context.allocator)
	project_root := fmt.aprintf("%s/project", directory, allocator = context.allocator)
	defer delete(project_root, context.allocator)
	instance_root := fmt.aprintf("%s/instance", directory, allocator = context.allocator)
	defer delete(instance_root, context.allocator)

	snapshot: process.Context_Snapshot
	init_err := process.context_snapshot_init(
		&snapshot,
		{
			window_id = 56,
			buffer_id = 78,
			file_path = file_path,
			address = "2,4",
			project_root = project_root,
			instance_root = instance_root,
			endpoint = "named-pipe:test",
			environment = {"CUSTOM=base", "PATH=", "ACME_FILE=stale"},
		},
		context.allocator,
	)
	if !expect_ok(t, init_err) {
		return
	}
	service: process.Job_Service
	process.job_service_init(&service, {}, context.allocator)
	defer expect_ok(t, process.job_service_destroy(&service))
	id, start_err := process.job_start_context(&service, {HELPER, "context"}, &snapshot, nil, 90)
	expect_ok(t, start_err)
	process.context_snapshot_destroy(&snapshot)
	job := process.job_find(&service, id)
	testing.expect(t, job != nil && job.working_dir == nested)
	testing.expect(t, context_value(job.environment, "ACME_FILE") == file_path)
	stdout := make([dynamic]byte, 0, 4096, context.allocator)
	defer delete(stdout)
	stderr := make([dynamic]byte, 0, 1024, context.allocator)
	defer delete(stderr)
	poll_job_until_releasable(t, &service, id, &stdout, &stderr)
	expected := fmt.aprintf(
		"cwd=%s\nACME_WINDOW_ID=56\nACME_BUFFER_ID=78\nACME_FILE=%s\nACME_ADDRESS=2,4\n" +
		"ACME_PROJECT_ROOT=%s\nACME_INSTANCE_ROOT=%s\nACME_ENDPOINT=named-pipe:test\nCUSTOM=base\nPATH=\n",
		nested,
		file_path,
		project_root,
		instance_root,
		allocator = context.allocator,
	)
	defer delete(expected, context.allocator)
	testing.expectf(t, string(stdout[:]) == expected, "context output %q, want %q", string(stdout[:]), expected)
	testing.expect(t, len(stderr) == 0 && job.exit_status.success && job.err.kind == .None)
	expect_ok(t, process.job_release(&service, id))
}
