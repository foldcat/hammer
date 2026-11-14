package journal_test

import "core:os"
import "core:testing"

import errs "hammer:core/errs"
import journal "hammer:core/journal"

expect_checkpoint_error :: proc(t: ^testing.T, path: string, kind: errs.Kind, limits := journal.Limits{}) {
	checkpoint, err := journal.read_checkpoint(path, limits, context.allocator)
	expect_kind(t, err, kind)
	journal.checkpoint_destroy(&checkpoint)
}

@(test)
test_checkpoint_round_trip_and_checkpoint_tail_recovery :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	checkpoint_path := generation_path(dir, "checkpoint", 3)
	tail_path := generation_path(dir, "journal", 3)
	header := test_header("document")
	header.generation = 3
	header.created_unix_ns = 987654321
	snapshot := []byte{0, 1, 2, 0xff, 'x'}
	if !expect_ok(t, journal.write_checkpoint(checkpoint_path, header, snapshot, {}, context.allocator)) {return}
	writer, ok := create_writer(t, tail_path, header)
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 100, transmute([]byte)string("tail one"))
	append_record(t, &writer, 2, 200, transmute([]byte)string("tail two"))
	close_writer(t, &writer)

	checkpoint, err := journal.read_checkpoint(checkpoint_path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, checkpoint.header.generation == 3)
	testing.expect(t, checkpoint.header.created_unix_ns == 987654321)
	testing.expect(t, len(checkpoint.snapshot) == len(snapshot))
	for i in 0 ..< len(snapshot) {
		testing.expect(t, checkpoint.snapshot[i] == snapshot[i])
	}
	journal.checkpoint_destroy(&checkpoint)

	recovered, recover_err := journal.recover_generation(checkpoint_path, tail_path, {}, context.allocator)
	if !expect_ok(t, recover_err) {return}
	defer journal.generation_destroy(&recovered)
	testing.expect(t, recovered.checkpoint.header.generation == 3)
	testing.expect(t, len(recovered.checkpoint.snapshot) == len(snapshot))
	testing.expect(t, recovered.tail.status == .Complete)
	if !testing.expect(t, len(recovered.tail.records) == 2) {return}
	testing.expect(t, string(recovered.tail.records[0].payload) == "tail one")
	testing.expect(t, string(recovered.tail.records[1].payload) == "tail two")
	testing.expect(t, journal.validate_identity(recovered.checkpoint.header, header.path, header.stamp, header.base_hash) == .Match)
}

@(test)
test_checkpoint_rejects_corruption_torn_data_and_limits :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := generation_path(dir, "checkpoint", 1)
	header := test_header("checkpoint")
	header.generation = 1
	snapshot := transmute([]byte)string("complete snapshot")
	if !expect_ok(t, journal.write_checkpoint(path, header, snapshot, {flush = .None}, context.allocator)) {return}
	expect_kind(t, journal.write_checkpoint(path, header, snapshot, {}, context.allocator), .Conflict)
	original := read_fixture(t, path)
	defer delete(original, context.allocator)
	mutated := make([]byte, len(original) + 1, context.allocator)
	defer delete(mutated, context.allocator)
	header_bytes := journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path)

	copy(mutated, original)
	mutated[journal.CHECKPOINT_FIXED_SIZE + header_bytes] ~= 0xff
	write_fixture(t, path, mutated[:len(original)])
	expect_checkpoint_error(t, path, .Invalid_Input)

	copy(mutated, original)
	write_fixture(t, path, mutated[:len(original) - 1])
	expect_checkpoint_error(t, path, .Invalid_Input)

	copy(mutated, original)
	mutated[len(original)] = 0
	write_fixture(t, path, mutated)
	expect_checkpoint_error(t, path, .Invalid_Input)

	write_fixture(t, path, original)
	expect_checkpoint_error(t, path, .Resource_Limit, {max_path_bytes = len(header.path) - 1})
	expect_checkpoint_error(t, path, .Resource_Limit, {max_file_bytes = i64(len(original) - 1)})

	too_small := generation_path(dir, "checkpoint", 99)
	expect_kind(t, journal.write_checkpoint(
		too_small,
		header,
		snapshot,
		{limits = {max_file_bytes = i64(len(original) - 1)}},
		context.allocator,
	), .Resource_Limit)
	testing.expect(t, !os.exists(too_small))
}

@(test)
test_recovery_rejects_mismatched_generation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	checkpoint_path := generation_path(dir, "checkpoint", 2)
	tail_path := generation_path(dir, "journal", 3)
	checkpoint_header := test_header("same-document")
	checkpoint_header.generation = 2
	if !expect_ok(t, journal.write_checkpoint(checkpoint_path, checkpoint_header, transmute([]byte)string("base"), {}, context.allocator)) {return}
	tail_header := checkpoint_header
	tail_header.generation = 3
	writer, ok := create_writer(t, tail_path, tail_header, {flush = .None})
	if !ok {return}
	close_writer(t, &writer)
	recovered, err := journal.recover_generation(checkpoint_path, tail_path, {}, context.allocator)
	expect_kind(t, err, .Conflict)
	journal.generation_destroy(&recovered)
}
