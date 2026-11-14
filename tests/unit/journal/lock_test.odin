package journal_test

import "core:os"
import "core:testing"

import journal "hammer:core/journal"

@(test)
test_session_lock_new_active_heartbeat_and_stale_cycle :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := generation_path(dir, "session", 1)
	first, acquired, err := journal.acquire(path, 11, 101, 1000, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.lock_release(&first)
	testing.expect(t, acquired.state == .Acquired_New && !acquired.previous_valid)
	testing.expect(t, first.record.pid == u64(os.get_pid()))

	second, active, second_err := journal.acquire(path, 22, 202, 2000, context.allocator)
	if !expect_ok(t, second_err) {return}
	testing.expect(t, active.state == .Active && active.previous_valid)
	testing.expect(t, active.previous.session_id == 11 && active.previous.process_instance_id == 101)
	testing.expect(t, second.file == nil)
	if !expect_ok(t, journal.lock_heartbeat(&first, 3000)) {return}

	second, active, err = journal.acquire(path, 22, 202, 3000, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, active.state == .Active && active.previous_valid)
	testing.expect(t, active.previous.heartbeat_unix_ns == 3000)
	if !expect_ok(t, journal.lock_release(&first)) {return}

	third, stale, third_err := journal.acquire(path, 33, 303, 4000, context.allocator)
	if !expect_ok(t, third_err) {return}
	defer journal.lock_release(&third)
	testing.expect(t, stale.state == .Acquired_Stale && stale.previous_valid)
	testing.expect(t, stale.previous.process_instance_id == 101)
	testing.expect(t, stale.previous.heartbeat_unix_ns == 3000)
	testing.expect(t, third.record.process_instance_id == 303)
	if !expect_ok(t, journal.lock_release(&third)) {return}
	expect_ok(t, journal.lock_release(&third))
	testing.expect(t, os.exists(path))
}

@(test)
test_corrupt_metadata_never_overrides_os_lock_state :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := generation_path(dir, "session", 2)
	first, acquired, err := journal.acquire(path, 11, 101, 1000, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.lock_release(&first)
	testing.expect(t, acquired.state == .Acquired_New)
	write_fixture(t, path, transmute([]byte)string("torn and invalid"))

	second, active, second_err := journal.acquire(path, 22, 202, 2000, context.allocator)
	if !expect_ok(t, second_err) {return}
	testing.expect(t, active.state == .Active && !active.previous_valid)
	testing.expect(t, second.file == nil)
	if !expect_ok(t, journal.lock_release(&first)) {return}

	third, stale, third_err := journal.acquire(path, 33, 303, 3000, context.allocator)
	if !expect_ok(t, third_err) {return}
	defer journal.lock_release(&third)
	testing.expect(t, stale.state == .Acquired_Stale && !stale.previous_valid)
	if !expect_ok(t, journal.lock_release(&third)) {return}

	fourth, fourth_stale, fourth_err := journal.acquire(path, 44, 404, 4000, context.allocator)
	if !expect_ok(t, fourth_err) {return}
	defer journal.lock_release(&fourth)
	testing.expect(t, fourth_stale.state == .Acquired_Stale && fourth_stale.previous_valid)
	testing.expect(t, fourth_stale.previous.process_instance_id == 303)
}

@(test)
test_oversized_stale_record_is_replaced_with_bounded_record :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	path := generation_path(dir, "session", 3)
	oversized := make([]byte, 4096, context.allocator)
	defer delete(oversized, context.allocator)
	write_fixture(t, path, oversized)
	lock, acquired, err := journal.acquire(path, 1, 1, 1, context.allocator)
	if !expect_ok(t, err) {return}
	defer journal.lock_release(&lock)
	testing.expect(t, acquired.state == .Acquired_Stale && !acquired.previous_valid)
	data := read_fixture(t, path)
	defer delete(data, context.allocator)
	testing.expect(t, len(data) == journal.LOCK_RECORD_SIZE)
}

@(test)
test_session_lock_invalid_input_and_open_failure :: proc(t: ^testing.T) {
	_, _, err := journal.acquire("", 1, 1, 1, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, _, err = journal.acquire("unused", 0, 1, 1, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	_, _, err = journal.acquire("unused", 1, 0, 1, context.allocator)
	expect_kind(t, err, .Invalid_Input)

	dir := sandbox(t)
	if dir == "" {return}
	defer sandbox_destroy(dir)
	missing := generation_path(dir, "missing", 1)
	path := generation_path(missing, "session", 1)
	_, _, err = journal.acquire(path, 1, 1, 1, context.allocator)
	expect_kind(t, err, .IO)
	expect_ok(t, journal.lock_release(nil))
}
