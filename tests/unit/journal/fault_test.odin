package journal_test

import "core:os"
import "core:testing"

import journal "hammer:core/journal"

Fault_State :: struct {
	calls:          int,
	fail_call:      int,
	max_write:      int,
	close_calls:    int,
	fail_close_call: int,
	fail_sync:      bool,
	fail_remove:    bool,
}

fault_error :: proc() -> os.Error {
	return os.General_Error.Broken_Pipe
}

fault_write :: proc(data: rawptr, file: ^os.File, bytes: []byte) -> (int, os.Error) {
	state := (^Fault_State)(data)
	state.calls += 1
	if state.fail_call > 0 && state.calls == state.fail_call {
		return 0, fault_error()
	}
	n := len(bytes)
	if state.max_write > 0 {
		n = min(n, state.max_write)
	}
	return os.write(file, bytes[:n])
}

fault_sync :: proc(data: rawptr, file: ^os.File) -> os.Error {
	state := (^Fault_State)(data)
	if state.fail_sync {
		return fault_error()
	}
	return os.sync(file)
}

fault_close :: proc(data: rawptr, file: ^os.File) -> os.Error {
	state := (^Fault_State)(data)
	state.close_calls += 1
	close_err := os.close(file)
	if state.close_calls == state.fail_close_call {
		return fault_error()
	}
	return close_err
}

fault_remove :: proc(data: rawptr, path: string) -> os.Error {
	state := (^Fault_State)(data)
	if state.fail_remove {
		return fault_error()
	}
	return os.remove(path)
}

@(test)
test_short_writes_complete_and_failed_append_preserves_prefix :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	header := test_header("fault")
	state := Fault_State{max_write = 1}
	hooks := journal.Operation_Hooks{data = &state, write = fault_write, sync = fault_sync}
	writer, ok := create_writer(t, path, header, {flush = .None, operations = &hooks})
	if !ok {return}
	defer journal.writer_close(&writer)
	append_record(t, &writer, 1, 1, transmute([]byte)string("valid"))
	state.fail_call = state.calls + 5
	expect_kind(t, journal.writer_append(&writer, 2, 2, transmute([]byte)string("torn")), .IO)
	expect_kind(t, journal.writer_append(&writer, 3, 3, transmute([]byte)string("hidden")), .Conflict)
	close_writer(t, &writer)
	header_bytes := i64(journal.HEADER_FIXED_SIZE + journal.HEADER_TRAILER_SIZE + len(header.path))
	first_end := header_bytes + journal.RECORD_HEADER_SIZE + journal.RECORD_TRAILER_SIZE + 5
	expect_prefix(t, path, {}, .Torn_Record, 1, first_end)
	result, err := journal.replay(path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.replay_destroy(&result)
	testing.expect(t, string(result.records[0].payload) == "valid")
}

@(test)
test_sync_failure_is_reported_and_poisons_writer :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	state := Fault_State{}
	hooks := journal.Operation_Hooks{data = &state, sync = fault_sync}
	writer, ok := create_writer(t, path, test_header("sync"), {operations = &hooks})
	if !ok {return}
	defer journal.writer_close(&writer)
	state.fail_sync = true
	expect_kind(t, journal.writer_append(&writer, 1, 1, transmute([]byte)string("written")), .IO)
	expect_kind(t, journal.writer_sync(&writer), .Conflict)
	expect_kind(t, journal.writer_append(&writer, 2, 2, nil), .Conflict)
	close_writer(t, &writer)
	result, err := journal.replay(path, {}, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.replay_destroy(&result)
	testing.expect(t, result.status == .Complete && len(result.records) == 1)
	testing.expect(t, string(result.records[0].payload) == "written")
}

@(test)
test_failed_create_removes_only_its_new_file :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := journal_path(dir)
	state := Fault_State{fail_call = 1}
	hooks := journal.Operation_Hooks{data = &state, write = fault_write}
	_, err := journal.create(path, test_header("create-fault"), {operations = &hooks}, context.allocator)
	expect_kind(t, err, .IO)
	testing.expect(t, !os.exists(path))
}

@(test)
test_checkpoint_sync_failure_removes_unpublished_file :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := generation_path(dir, "checkpoint", 1)
	state := Fault_State{fail_sync = true}
	hooks := journal.Operation_Hooks{data = &state, sync = fault_sync, close = fault_close}
	header := test_header("checkpoint-sync")
	header.generation = 1
	err := journal.write_checkpoint(path, header, transmute([]byte)string("snapshot"), {operations = &hooks}, context.allocator)
	expect_kind(t, err, .IO)
	testing.expect(t, !os.exists(path))
}
