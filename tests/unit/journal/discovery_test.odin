package journal_test

import "core:os"
import "core:testing"

import journal "hammer:core/journal"

write_generation :: proc(t: ^testing.T, dir: string, generation: u64, snapshot: string, payloads: []string) {
	header := test_header("discovery")
	header.generation = generation
	header.created_unix_ns = i64(generation) * 100
	checkpoint_path := generation_path(dir, "checkpoint", generation)
	journal_file := generation_path(dir, "journal", generation)
	if !expect_ok(t, journal.write_checkpoint(checkpoint_path, header, transmute([]byte)snapshot, {flush = .None}, context.allocator)) {return}
	writer, ok := create_writer(t, journal_file, header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	for payload, index in payloads {
		append_record(t, &writer, u64(index + 1), i64(index), transmute([]byte)payload)
	}
	close_writer(t, &writer)
}

has_discovery_issue :: proc(discovery: journal.Discovery, generation: u64, reason: journal.Discovery_Issue_Reason) -> bool {
	for issue in discovery.issues {
		if issue.generation == generation && issue.reason == reason {
			return true
		}
	}
	return false
}

@(test)
test_discovery_selects_highest_valid_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	write_generation(t, dir, 1, "one", []string{"old"})
	write_generation(t, dir, 2, "two", []string{"new", "tail"})
	manifest := generation_path(dir, "manifest", 99)
	write_fixture(t, manifest, transmute([]byte)string("not a generation"))

	discovery, err := journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.discovery_destroy(&discovery)
	testing.expect(t, discovery.found && discovery.generation == 2)
	testing.expect(t, discovery.scanned_entries == 5)
	testing.expect(t, string(discovery.recovered.checkpoint.snapshot) == "two")
	testing.expect(t, len(discovery.recovered.tail.records) == 2)
	testing.expect(t, string(discovery.recovered.tail.records[1].payload) == "tail")
	testing.expect(t, len(discovery.issues) == 0)
	testing.expect(t, discovery.checkpoint_path == generation_path(dir, "checkpoint", 2))
	testing.expect(t, discovery.journal_path == generation_path(dir, "journal", 2))
	testing.expect(t, os.exists(generation_path(dir, "checkpoint", 1)))
	testing.expect(t, os.exists(generation_path(dir, "journal", 2)))
}

@(test)
test_discovery_falls_back_from_corrupt_and_mismatched_generations :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	write_generation(t, dir, 1, "safe", []string{"recover"})
	write_generation(t, dir, 2, "mismatch", nil)
	write_generation(t, dir, 3, "corrupt", []string{"ignored"})

	mismatched_path := generation_path(dir, "journal", 2)
	bad_header := test_header("discovery")
	bad_header.generation = 3
	if !expect_os_ok(t, os.remove(mismatched_path)) {return}
	bad_writer, ok := create_writer(t, mismatched_path, bad_header, {flush = .None})
	if !ok {return}
	// Replace the valid generation-2 journal with a same-path generation-3 one.
	close_writer(t, &bad_writer)

	corrupt_path := generation_path(dir, "checkpoint", 3)
	data := read_fixture(t, corrupt_path)
	mutated := make([]byte, len(data), context.allocator)
	copy(mutated, data)
	mutated[len(mutated) - 1] ~= 1
	write_fixture(t, corrupt_path, mutated)
	delete(mutated, context.allocator)
	delete(data, context.allocator)

	discovery, err := journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.discovery_destroy(&discovery)
	testing.expect(t, discovery.found && discovery.generation == 1)
	testing.expect(t, string(discovery.recovered.checkpoint.snapshot) == "safe")
	testing.expect(t, has_discovery_issue(discovery, 3, .Invalid_Checkpoint))
	testing.expect(t, has_discovery_issue(discovery, 2, .Generation_Mismatch))
	testing.expect(t, os.exists(corrupt_path) && os.exists(mismatched_path))
}

@(test)
test_discovery_uses_verified_prefix_of_torn_latest_tail :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	write_generation(t, dir, 2, "snapshot", []string{"first", "second"})
	tail_path := generation_path(dir, "journal", 2)
	data := read_fixture(t, tail_path)
	write_fixture(t, tail_path, data[:len(data) - 5])
	delete(data, context.allocator)

	discovery, err := journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.discovery_destroy(&discovery)
	testing.expect(t, discovery.found && discovery.generation == 2)
	testing.expect(t, discovery.recovered.tail.status == .Torn_Record)
	testing.expect(t, len(discovery.recovered.tail.records) == 1)
	testing.expect(t, string(discovery.recovered.tail.records[0].payload) == "first")
}

@(test)
test_discovery_supports_initial_journal_and_checkpoint_only :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	initial_header := test_header("initial")
	initial_header.generation = 0
	initial_path := generation_path(dir, "journal", 0)
	writer, ok := create_writer(t, initial_path, initial_header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("initial"))
	close_writer(t, &writer)

	orphan_header := test_header("orphan")
	orphan_header.generation = 2
	orphan_path := generation_path(dir, "journal", 2)
	orphan, orphan_ok := create_writer(t, orphan_path, orphan_header, {flush = .None})
	if !orphan_ok {return}
	close_writer(t, &orphan)

	discovery, err := journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, discovery.found && discovery.generation == 0)
	testing.expect(t, discovery.checkpoint_path == "")
	testing.expect(t, len(discovery.recovered.tail.records) == 1)
	testing.expect(t, has_discovery_issue(discovery, 2, .Missing_Checkpoint))
	journal.discovery_destroy(&discovery)

	checkpoint_only := generation_path(dir, "checkpoint", 3)
	checkpoint_header := test_header("checkpoint-only")
	checkpoint_header.generation = 3
	if !expect_ok(t, journal.write_checkpoint(checkpoint_only, checkpoint_header, transmute([]byte)string("complete"), {}, context.allocator)) {return}
	discovery, err = journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.discovery_destroy(&discovery)
	testing.expect(t, discovery.found && discovery.generation == 3)
	testing.expect(t, discovery.journal_path == "")
	testing.expect(t, string(discovery.recovered.checkpoint.snapshot) == "complete")
	testing.expect(t, len(discovery.recovered.tail.records) == 0)
}

@(test)
test_discovery_entry_bounds_and_empty_directory :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	discovery, err := journal.discover(dir, {}, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, !discovery.found && discovery.scanned_entries == 0)
	journal.discovery_destroy(&discovery)

	first := generation_path(dir, "notes", 1)
	second := generation_path(dir, "notes", 2)
	write_fixture(t, first, transmute([]byte)string("a"))
	discovery, err = journal.discover(dir, {max_entries = 1}, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, !discovery.found && discovery.scanned_entries == 1)
	journal.discovery_destroy(&discovery)
	write_fixture(t, second, transmute([]byte)string("b"))
	_, err = journal.discover(dir, {max_entries = 1}, context.allocator)
	expect_kind(t, err, .Resource_Limit)
	testing.expect(t, os.exists(first) && os.exists(second))
	_, err = journal.discover(dir, {max_entries = -1}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
}

@(test)
test_discovery_does_not_follow_symlinked_journal :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dir := sandbox(t)
		if dir == "" {return}
		defer sandbox_destroy(dir)
		write_generation(t, dir, 1, "safe", nil)
		target_header := test_header("target")
		target_header.generation = 2
		target := generation_path(dir, "target", 2)
		writer, ok := create_writer(t, target, target_header, {flush = .None})
		if !ok {return}
		close_writer(t, &writer)
		link := generation_path(dir, "journal", 2)
		if !expect_os_ok(t, os.symlink(target, link)) {return}
		discovery, err := journal.discover(dir, {}, context.allocator)
		if !expect_ok(t, err) {return}
		defer journal.discovery_destroy(&discovery)
		testing.expect(t, discovery.found && discovery.generation == 1)
		testing.expect(t, os.exists(link))
	}
}
