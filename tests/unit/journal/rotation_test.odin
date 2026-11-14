package journal_test

import "core:os"
import "core:testing"

import journal "hammer:core/journal"

@(test)
test_rotation_policy_uses_time_size_and_count :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	writer, ok := create_writer(t, journal_path(dir), test_header("policy"), {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	testing.expect(t, !journal.rotation_due(&writer, 1000, 1000, {}))
	policy := journal.Rotation_Policy{interval_ns = 100, max_journal_bytes = 1 << 30, max_records = 100}
	testing.expect(t, !journal.rotation_due(&writer, 1000, 1099, policy))
	testing.expect(t, journal.rotation_due(&writer, 1000, 1100, policy))
	testing.expect(t, !journal.rotation_due(&writer, 1100, 1000, policy))
	testing.expect(t, journal.rotation_due(&writer, 1000, 1000, {interval_ns = 1, max_journal_bytes = writer.bytes_written, max_records = 100}))
	append_record(t, &writer, 1, 1, nil)
	testing.expect(t, journal.rotation_due(&writer, 1000, 1000, {interval_ns = 1 << 40, max_journal_bytes = 1 << 30, max_records = 1}))
	testing.expect(t, !journal.rotation_due(&writer, 1000, 1000, {interval_ns = -1, max_journal_bytes = -1, max_records = -1}))
	close_writer(t, &writer)
}

@(test)
test_successful_rotation_replaces_old_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	old_checkpoint := generation_path(dir, "checkpoint", 1)
	old_journal := generation_path(dir, "journal", 1)
	new_checkpoint := generation_path(dir, "checkpoint", 2)
	new_journal := generation_path(dir, "journal", 2)
	header := test_header("rotate")
	header.generation = 1
	header.created_unix_ns = 100
	if !expect_ok(t, journal.write_checkpoint(old_checkpoint, header, transmute([]byte)string("old base"), {}, context.allocator)) {return}
	writer, ok := create_writer(t, old_journal, header)
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("old tail"))

	rotated, err := journal.rotate(&writer, old_checkpoint, old_journal, new_checkpoint, new_journal, header, transmute([]byte)string("bad"), context.allocator)
	testing.expect(t, !rotated)
	expect_kind(t, err, .Conflict)
	testing.expect(t, os.exists(old_journal) && !os.exists(new_journal))

	next_header := header
	next_header.generation = 2
	next_header.created_unix_ns = 200
	rotated, err = journal.rotate(&writer, old_checkpoint, old_journal, new_checkpoint, new_journal, next_header, transmute([]byte)string("new base"), context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, rotated && writer.generation == 2 && writer.next_sequence == 1)
	testing.expect(t, !os.exists(old_checkpoint) && !os.exists(old_journal))
	append_record(t, &writer, 1, 300, transmute([]byte)string("new tail"))
	close_writer(t, &writer)

	recovered, recover_err := journal.recover_generation(new_checkpoint, new_journal, {}, context.allocator)
	if !expect_ok(t, recover_err) {return}
	defer journal.generation_destroy(&recovered)
	testing.expect(t, string(recovered.checkpoint.snapshot) == "new base")
	testing.expect(t, len(recovered.tail.records) == 1)
	testing.expect(t, string(recovered.tail.records[0].payload) == "new tail")
}

@(test)
test_failed_rotation_preserves_current_writer_and_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	old_checkpoint := generation_path(dir, "checkpoint", 1)
	old_journal := generation_path(dir, "journal", 1)
	new_checkpoint := generation_path(dir, "checkpoint", 2)
	new_journal := generation_path(dir, "journal", 2)
	header := test_header("interrupted")
	header.generation = 1
	if !expect_ok(t, journal.write_checkpoint(old_checkpoint, header, transmute([]byte)string("old base"), {}, context.allocator)) {return}
	state := Fault_State{}
	hooks := journal.Operation_Hooks{data = &state, write = fault_write, sync = fault_sync, close = fault_close, remove = fault_remove}
	writer, ok := create_writer(t, old_journal, header, {flush = .None, operations = &hooks})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("one"))
	state.fail_call = state.calls + 4
	next_header := header
	next_header.generation = 2
	rotated, err := journal.rotate(&writer, old_checkpoint, old_journal, new_checkpoint, new_journal, next_header, transmute([]byte)string("new base"), context.allocator)
	testing.expect(t, !rotated)
	expect_kind(t, err, .IO)
	testing.expect(t, writer.generation == 1 && writer.next_sequence == 2)
	testing.expect(t, os.exists(old_checkpoint) && os.exists(old_journal))
	testing.expect(t, !os.exists(new_checkpoint) && !os.exists(new_journal))
	append_record(t, &writer, 2, 2, transmute([]byte)string("two"))
	close_writer(t, &writer)

	recovered, recover_err := journal.recover_generation(old_checkpoint, old_journal, {}, context.allocator)
	if !expect_ok(t, recover_err) {return}
	defer journal.generation_destroy(&recovered)
	testing.expect(t, len(recovered.tail.records) == 2)
	testing.expect(t, string(recovered.tail.records[1].payload) == "two")
}

@(test)
test_post_rotation_cleanup_failure_reports_new_active_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	old_checkpoint := generation_path(dir, "checkpoint", 1)
	old_journal := generation_path(dir, "journal", 1)
	new_checkpoint := generation_path(dir, "checkpoint", 2)
	new_journal := generation_path(dir, "journal", 2)
	header := test_header("cleanup")
	header.generation = 1
	if !expect_ok(t, journal.write_checkpoint(old_checkpoint, header, transmute([]byte)string("old base"), {}, context.allocator)) {return}
	state := Fault_State{}
	hooks := journal.Operation_Hooks{data = &state, close = fault_close, remove = fault_remove}
	writer, ok := create_writer(t, old_journal, header, {flush = .None, operations = &hooks})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("old tail"))
	state.fail_remove = true
	next_header := header
	next_header.generation = 2
	rotated, err := journal.rotate(&writer, old_checkpoint, old_journal, new_checkpoint, new_journal, next_header, transmute([]byte)string("new base"), context.allocator)
	expect_kind(t, err, .IO)
	testing.expect(t, rotated && writer.generation == 2)
	testing.expect(t, os.exists(old_checkpoint) && os.exists(old_journal))
	append_record(t, &writer, 1, 1, transmute([]byte)string("new tail"))
	close_writer(t, &writer)

	old, old_err := journal.recover_generation(old_checkpoint, old_journal, {}, context.allocator)
	if !expect_ok(t, old_err) {return}
	defer journal.generation_destroy(&old)
	testing.expect(t, len(old.tail.records) == 1)
	new, new_err := journal.recover_generation(new_checkpoint, new_journal, {}, context.allocator)
	if !expect_ok(t, new_err) {return}
	defer journal.generation_destroy(&new)
	testing.expect(t, string(new.checkpoint.snapshot) == "new base")
	testing.expect(t, len(new.tail.records) == 1)
}

@(test)
test_old_close_failure_still_activates_complete_new_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	old_checkpoint := generation_path(dir, "checkpoint", 1)
	old_journal := generation_path(dir, "journal", 1)
	new_checkpoint := generation_path(dir, "checkpoint", 2)
	new_journal := generation_path(dir, "journal", 2)
	header := test_header("close-failure")
	header.generation = 1
	if !expect_ok(t, journal.write_checkpoint(old_checkpoint, header, transmute([]byte)string("old"), {}, context.allocator)) {return}
	state := Fault_State{fail_close_call = 2}
	hooks := journal.Operation_Hooks{data = &state, close = fault_close}
	writer, ok := create_writer(t, old_journal, header, {flush = .None, operations = &hooks})
	if !ok {return}
	defer journal.writer_close(&writer)
	next_header := header
	next_header.generation = 2
	rotated, err := journal.rotate(&writer, old_checkpoint, old_journal, new_checkpoint, new_journal, next_header, transmute([]byte)string("new"), context.allocator)
	expect_kind(t, err, .IO)
	testing.expect(t, rotated && writer.generation == 2)
	testing.expect(t, !os.exists(old_checkpoint) && !os.exists(old_journal))
	close_writer(t, &writer)
	recovered, recover_err := journal.recover_generation(new_checkpoint, new_journal, {}, context.allocator)
	if !expect_ok(t, recover_err) {return}
	defer journal.generation_destroy(&recovered)
	testing.expect(t, string(recovered.checkpoint.snapshot) == "new")
}
