package journal_test

import "core:testing"

import fileid "hammer:core/fileid"
import journal "hammer:core/journal"

@(test)
test_round_trip_metadata_and_records :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header()
	writer, ok := create_writer(t, path, header)
	if !ok {return}
	defer journal.writer_close(&writer)
	first := transmute([]byte)string("first transaction")
	second := []byte{0, 1, 2, 0xff}
	if !append_record(t, &writer, 1, 1001, first) {return}
	if !append_record(t, &writer, 2, -1002, second) {return}
	if !append_record(t, &writer, 3, 1003, nil) {return}
	close_writer(t, &writer)

	result, err := journal.replay(path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.replay_destroy(&result)
	testing.expect(t, result.status == .Complete)
	testing.expect(t, result.header.path == header.path)
	testing.expect(t, fileid.stamp_equal(result.header.stamp, header.stamp))
	testing.expect(t, result.header.base_hash == header.base_hash)
	testing.expect(t, metadata_equal(result.header.encoding, header.encoding))
	testing.expect(t, result.header.session_id == header.session_id)
	testing.expect(t, result.header.process_instance_id == header.process_instance_id)
	testing.expect(t, result.header.created_unix_ns == header.created_unix_ns)
	if !testing.expect(t, len(result.records) == 3) {return}
	testing.expect(t, result.records[0].sequence == 1 && result.records[0].timestamp_unix_ns == 1001)
	testing.expect(t, string(result.records[0].payload) == "first transaction")
	testing.expect(t, len(result.records[1].payload) == len(second))
	for i in 0 ..< len(second) {
		testing.expect(t, result.records[1].payload[i] == second[i])
	}
	testing.expect(t, result.records[2].sequence == 3 && len(result.records[2].payload) == 0)
	data := read_fixture(t, path)
	defer delete(data, context.allocator)
	testing.expect(t, result.valid_bytes == i64(len(data)))
}

@(test)
test_every_torn_final_offset_preserves_valid_prefix :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("tear")
	writer, ok := create_writer(t, path, header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("one"))
	append_record(t, &writer, 2, 2, transmute([]byte)string("second"))
	close_writer(t, &writer)
	original := read_fixture(t, path)
	defer delete(original, context.allocator)
	header_bytes := i64(journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path))
	first_end := header_bytes + i64(journal.RECORD_HEADER_SIZE + journal.RECORD_TRAILER_SIZE + 3)

	expect_prefix(t, path, {}, .Complete, 2, i64(len(original)))
	for cut := int(header_bytes) + 1; cut < len(original); cut += 1 {
		if cut == int(first_end) {continue}
		if !write_fixture(t, path, original[:cut]) {return}
		expected_count := 0 if cut < int(first_end) else 1
		expected_valid := header_bytes if expected_count == 0 else first_end
		expect_prefix(t, path, {}, .Torn_Record, expected_count, expected_valid)
	}
	write_fixture(t, path, original[:first_end])
	expect_prefix(t, path, {}, .Complete, 1, first_end)
}

@(test)
test_checksum_stops_before_corrupt_and_later_records :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("checksum")
	writer, ok := create_writer(t, path, header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("one"))
	append_record(t, &writer, 2, 2, transmute([]byte)string("two"))
	append_record(t, &writer, 3, 3, transmute([]byte)string("three"))
	close_writer(t, &writer)
	original := read_fixture(t, path)
	defer delete(original, context.allocator)
	header_bytes := journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path)
	second_start := header_bytes + journal.RECORD_HEADER_SIZE + 3 + journal.RECORD_TRAILER_SIZE
	mutated := make([]byte, len(original), context.allocator)
	defer delete(mutated, context.allocator)
	copy(mutated, original)
	mutated[second_start + journal.RECORD_HEADER_SIZE] ~= 0xff
	write_fixture(t, path, mutated)
	expect_prefix(t, path, {}, .Checksum_Mismatch, 1, i64(second_start))
}

@(test)
test_record_version_sequence_and_payload_length_are_validated :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("fields")
	writer, ok := create_writer(t, path, header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("one"))
	append_record(t, &writer, 2, 2, transmute([]byte)string("two"))
	close_writer(t, &writer)
	original := read_fixture(t, path)
	defer delete(original, context.allocator)
	header_bytes := journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path)
	second_start := header_bytes + journal.RECORD_HEADER_SIZE + 3 + journal.RECORD_TRAILER_SIZE
	mutated := make([]byte, len(original), context.allocator)
	defer delete(mutated, context.allocator)

	copy(mutated, original)
	mutated[second_start + 4] = 99
	write_fixture(t, path, mutated)
	expect_prefix(t, path, {}, .Unsupported_Record_Version, 1, i64(second_start))

	copy(mutated, original)
	mutated[second_start + 8] = 9
	write_fixture(t, path, mutated)
	expect_prefix(t, path, {}, .Sequence_Mismatch, 1, i64(second_start))

	copy(mutated, original)
	mutated[second_start] = 5
	mutated[second_start + 1] = 0
	mutated[second_start + 2] = 0
	mutated[second_start + 3] = 0
	write_fixture(t, path, mutated)
	expect_prefix(t, path, {max_payload_bytes = 4}, .Payload_Limit, 1, i64(second_start))
}

@(test)
test_header_validation_and_exclusive_creation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("header")
	writer, ok := create_writer(t, path, header, {flush = .None})
	if !ok {return}
	_, create_err := journal.create(path, header, {}, context.allocator)
	expect_kind(t, create_err, .Conflict)
	close_writer(t, &writer)
	original := read_fixture(t, path)
	defer delete(original, context.allocator)
	mutated := make([]byte, len(original), context.allocator)
	defer delete(mutated, context.allocator)

	copy(mutated, original)
	mutated[80] ~= 1
	write_fixture(t, path, mutated)
	expect_replay_error(t, path, .Invalid_Input)

	copy(mutated, original)
	mutated[12] = 99
	write_fixture(t, path, mutated)
	expect_replay_error(t, path, .Unsupported)

	write_fixture(t, path, original[:100])
	expect_replay_error(t, path, .Invalid_Input)
}

@(test)
test_writer_and_replay_limits :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("limits")
	header_bytes := i64(journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path))
	options := journal.Options {
		flush = .None,
		limits = {max_payload_bytes = 4, max_records = 2, max_file_bytes = header_bytes + 2 * (journal.RECORD_HEADER_SIZE + journal.RECORD_TRAILER_SIZE + 3)},
	}
	writer, ok := create_writer(t, path, header, options)
	if !ok {return}
	defer journal.writer_close(&writer)
	expect_kind(t, journal.writer_append(&writer, 1, 0, transmute([]byte)string("large")), .Resource_Limit)
	append_record(t, &writer, 1, 1, transmute([]byte)string("one"))
	append_record(t, &writer, 2, 2, transmute([]byte)string("two"))
	expect_kind(t, journal.writer_append(&writer, 3, 3, transmute([]byte)string("six")), .Resource_Limit)
	close_writer(t, &writer)

	expect_prefix(t, path, {}, .Complete, 2, options.limits.max_file_bytes)
	expect_prefix(t, path, {max_records = 1}, .Record_Limit, 1, header_bytes + journal.RECORD_HEADER_SIZE + journal.RECORD_TRAILER_SIZE + 3)
	expect_prefix(t, path, {max_file_bytes = header_bytes + 1}, .File_Limit, 0, header_bytes)
	expect_replay_error(t, path, .Resource_Limit, {max_path_bytes = len(header.path) - 1})
}

@(test)
test_identity_validation_is_strict :: proc(t: ^testing.T) {
	header := test_header()
	stamp := header.stamp
	hash := header.base_hash
	testing.expect(t, journal.validate_identity(header, header.path, stamp, hash) == .Match)
	testing.expect(t, journal.validate_identity(header, "other", stamp, hash) == .Path_Mismatch)
	bad_hash := hash
	bad_hash[0] ~= 1
	testing.expect(t, journal.validate_identity(header, header.path, stamp, bad_hash) == .Base_Hash_Mismatch)
	replaced := stamp
	replaced.id = fileid.unix_id(41, 100)
	testing.expect(t, journal.validate_identity(header, header.path, replaced, hash) == .File_Replaced)
	modified := stamp
	modified.size += 1
	testing.expect(t, journal.validate_identity(header, header.path, modified, hash) == .File_Modified)
	unverified := stamp
	unverified.id = fileid.FILE_ID_NONE
	testing.expect(t, journal.validate_identity(header, header.path, unverified, hash) == .Identity_Unverified)
	testing.expect(t, journal.validate_identity(header, header.path, unverified, hash, true) == .Match)
}

@(test)
test_base_hash_uses_sha256 :: proc(t: ^testing.T) {
	digest := journal.hash_base(transmute([]byte)string("abc"))
	expected := [32]u8{
		0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
		0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
		0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
		0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
	}
	testing.expect(t, digest == expected)
}

@(test)
test_seeded_random_round_trip :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	writer, ok := create_writer(t, path, test_header("random"), {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	state := u64(0x7265_636f_7665_7279)
	payloads: [64][]byte
	defer for payload in payloads {
		delete(payload, context.allocator)
	}
	for i in 0 ..< len(payloads) {
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		length := int(state % 128)
		payloads[i] = make([]byte, length, context.allocator)
		for j in 0 ..< length {
			state ~= state << 13
			state ~= state >> 7
			state ~= state << 17
			payloads[i][j] = byte(state)
		}
		append_record(t, &writer, u64(i + 1), i64(i) - 20, payloads[i])
	}
	close_writer(t, &writer)
	result, err := journal.replay(path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.replay_destroy(&result)
	testing.expect(t, result.status == .Complete)
	if !testing.expect(t, len(result.records) == len(payloads)) {return}
	for i in 0 ..< len(payloads) {
		testing.expect(t, result.records[i].sequence == u64(i + 1))
		testing.expect(t, result.records[i].timestamp_unix_ns == i64(i) - 20)
		testing.expect(t, len(result.records[i].payload) == len(payloads[i]))
		for j in 0 ..< len(payloads[i]) {
			testing.expect(t, result.records[i].payload[j] == payloads[i][j])
		}
	}
}

@(test)
test_untitled_empty_path_round_trip :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("")
	header.stamp.id = fileid.FILE_ID_NONE
	writer, ok := create_writer(t, path, header, {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("untitled"))
	close_writer(t, &writer)
	result, err := journal.replay(path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.replay_destroy(&result)
	testing.expect(t, result.status == .Complete && result.header.path == "")
	testing.expect(t, len(result.records) == 1 && string(result.records[0].payload) == "untitled")
}

@(test)
test_invalid_calls_and_input_do_not_mutate_journal :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	writer, ok := create_writer(t, path, test_header("order"), {flush = .None})
	if !ok {return}
	defer journal.writer_close(&writer)
	expect_kind(t, journal.writer_append(&writer, 2, 0, nil), .Conflict)
	append_record(t, &writer, 1, 1, nil)
	close_writer(t, &writer)
	expect_prefix(t, path, {}, .Complete, 1, i64(journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len("order") + journal.RECORD_HEADER_SIZE + journal.RECORD_TRAILER_SIZE))

	_, err := journal.create("", test_header(), {}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, err = journal.replay(path, {max_records = -1}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
}
