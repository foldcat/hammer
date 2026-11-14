package journal_test

import "core:fmt"
import "core:os"
import "core:testing"

import errs "hammer:core/errs"
import filecodec "hammer:core/filecodec"
import fileid "hammer:core/fileid"
import journal "hammer:core/journal"

sandbox :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "hammer-journal-*", context.allocator)
	if !expect_os_ok(t, err) {
		return ""
	}
	return dir
}

sandbox_destroy :: proc(dir: string) {
	os.remove_all(dir)
	delete(dir, context.allocator)
}

journal_path :: proc(dir: string) -> string {
	return fmt.tprintf("%s/recovery.journal", dir)
}

generation_path :: proc(dir, kind: string, generation: u64) -> string {
	return fmt.tprintf("%s/%s-%06d.bin", dir, kind, generation)
}

expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	description := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected error: %s", description)
	delete(description, context.allocator)
	local := err
	errs.destroy(&local)
	return false
}

expect_os_ok :: proc(t: ^testing.T, err: os.Error) -> bool {
	if err == nil {
		return true
	}
	testing.expectf(t, false, "unexpected OS error: %v", err)
	return false
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got error %v, expected %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

test_header :: proc(path := "/project/example.txt") -> journal.Header {
	return journal.Header {
		path = path,
		stamp = {
			id = fileid.unix_id(41, 99),
			size = 12345,
			mtime_sec = -123,
			mtime_nsec = 456789,
		},
		base_hash = journal.hash_base(transmute([]byte)string("base contents")),
		encoding = {
			encoding = .UTF8,
			bom = .UTF8,
			newline = .Mixed,
			newlines = {lf = 4, crlf = 3, cr = 2},
		},
		session_id = 0x0102_0304_0506_0708,
		process_instance_id = 0x1112_1314_1516_1718,
		created_unix_ns = -123456789,
	}
}

create_writer :: proc(t: ^testing.T, path: string, header: journal.Header, options := journal.Options{}) -> (journal.Writer, bool) {
	writer, err := journal.create(path, header, options, context.allocator)
	if !expect_ok(t, err) {
		return {}, false
	}
	return writer, true
}

close_writer :: proc(t: ^testing.T, writer: ^journal.Writer) {
	expect_ok(t, journal.writer_close(writer))
}

read_fixture :: proc(t: ^testing.T, path: string) -> []byte {
	data, err := os.read_entire_file(path, context.allocator)
	if !expect_os_ok(t, err) {
		return nil
	}
	return data
}

write_fixture :: proc(t: ^testing.T, path: string, data: []byte) -> bool {
	return expect_os_ok(t, os.write_entire_file(path, data))
}

append_record :: proc(t: ^testing.T, writer: ^journal.Writer, sequence: u64, timestamp: i64, payload: []byte) -> bool {
	return expect_ok(t, journal.writer_append(writer, sequence, timestamp, payload))
}

expect_replay_error :: proc(t: ^testing.T, path: string, kind: errs.Kind, limits := journal.Limits{}) {
	result, err := journal.replay(path, limits, context.allocator)
	expect_kind(t, err, kind)
	journal.replay_destroy(&result)
}

expect_prefix :: proc(
	t: ^testing.T,
	path: string,
	limits: journal.Limits,
	status: journal.Replay_Status,
	count: int,
	valid_bytes: i64,
) {
	result, err := journal.replay(path, limits, context.allocator)
	if !expect_ok(t, err) {
		return
	}
	defer journal.replay_destroy(&result)
	testing.expectf(t, result.status == status, "got replay status %v, expected %v", result.status, status)
	testing.expectf(t, len(result.records) == count, "got %d records, expected %d", len(result.records), count)
	testing.expect(t, result.valid_bytes == valid_bytes)
}

metadata_equal :: proc(a, b: filecodec.Metadata) -> bool {
	return a.encoding == b.encoding && a.bom == b.bom && a.newline == b.newline && a.newlines == b.newlines
}
