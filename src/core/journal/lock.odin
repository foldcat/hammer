package journal

import "base:runtime"
import "core:hash"
import "core:os"

import errs "../errs"

LOCK_FORMAT_VERSION :: u32(1)
LOCK_RECORD_SIZE :: 68
LOCK_MAGIC :: [8]u8{'H', 'M', 'L', 'K', '\r', '\n', 0x1a, '\n'}

// Lock_Record is diagnostic process-instance metadata. PID is never used alone
// or as a reason to break a lock; the operating-system file lock is authoritative.
Lock_Record :: struct {
	pid:                 u64,
	session_id:          u64,
	process_instance_id: u64,
	created_unix_ns:     i64,
	heartbeat_unix_ns:   i64,
}

Lock_State :: enum {
	Acquired_New,
	Acquired_Stale,
	Active,
}

Acquire_Result :: struct {
	state:          Lock_State,
	previous:       Lock_Record,
	previous_valid: bool,
}

// Session_Lock owns an open OS-locked handle. It is fixed-location, not
// thread-safe, and must be released with lock_release. Release leaves the file
// in place so another process cannot lock a replacement inode concurrently.
Session_Lock :: struct {
	file:      ^os.File,
	record:    Lock_Record,
	allocator: runtime.Allocator,
}

encode_lock_record :: proc(record: Lock_Record) -> [LOCK_RECORD_SIZE]byte {
	data: [LOCK_RECORD_SIZE]byte
	magic := LOCK_MAGIC
	copy(data[:len(magic)], magic[:])
	put_u32(data[:], 8, LOCK_FORMAT_VERSION)
	put_u32(data[:], 12, LOCK_RECORD_SIZE)
	put_u64(data[:], 16, record.pid)
	put_u64(data[:], 24, record.session_id)
	put_u64(data[:], 32, record.process_instance_id)
	put_i64(data[:], 40, record.created_unix_ns)
	put_i64(data[:], 48, record.heartbeat_unix_ns)
	put_u64(data[:], 56, 0)
	put_u32(data[:], 64, hash.crc32(data[:64]))
	return data
}

decode_lock_record :: proc(data: []byte) -> (record: Lock_Record, ok: bool) {
	if len(data) != LOCK_RECORD_SIZE {
		return {}, false
	}
	magic := LOCK_MAGIC
	for i in 0 ..< len(magic) {
		if data[i] != magic[i] {
			return {}, false
		}
	}
	if get_u32(data, 8) != LOCK_FORMAT_VERSION || get_u32(data, 12) != LOCK_RECORD_SIZE || get_u64(data, 56) != 0 {
		return {}, false
	}
	if get_u32(data, 64) != hash.crc32(data[:64]) {
		return {}, false
	}
	record.pid = get_u64(data, 16)
	record.session_id = get_u64(data, 24)
	record.process_instance_id = get_u64(data, 32)
	record.created_unix_ns = get_i64(data, 40)
	record.heartbeat_unix_ns = get_i64(data, 48)
	return record, true
}

read_previous_lock :: proc(file: ^os.File) -> (record: Lock_Record, valid, has_content: bool) {
	size, err := os.file_size(file)
	if err != nil || size <= 0 {
		return {}, false, false
	}
	has_content = true
	if size != LOCK_RECORD_SIZE {
		return {}, false, true
	}
	data: [LOCK_RECORD_SIZE]byte
	if _, read_err := os.read_at(file, data[:], 0); read_err != nil {
		return {}, false, true
	}
	record, valid = decode_lock_record(data[:])
	return record, valid, true
}

write_lock_record :: proc(file: ^os.File, record: Lock_Record) -> os.Error {
	if err := os.truncate(file, 0); err != nil {
		return err
	}
	data := encode_lock_record(record)
	if _, err := os.write_at(file, data[:], 0); err != nil {
		return err
	}
	return os.sync(file)
}

// acquire takes a nonblocking exclusive OS lock and then writes the caller's
// process-instance record. Active is a normal result with no owned Session_Lock.
// Existing metadata is read before replacement but never authorizes stale
// takeover; only successful OS lock acquisition does that.
acquire :: proc(
	path: string,
	session_id, process_instance_id: u64,
	now_unix_ns: i64,
	allocator := context.allocator,
) -> (Session_Lock, Acquire_Result, errs.Error) {
	if path == "" || session_id == 0 || process_instance_id == 0 {
		return {}, {}, errs.newf(.Invalid_Input, "journal: lock path must be non-empty and session/instance IDs nonzero", allocator = allocator)
	}
	file, open_err := os.open(path, {.Read, .Write, .Create}, {.Read_User, .Write_User})
	if open_err != nil {
		return {}, {}, errs.newf(.IO, "journal: cannot open session lock %s: %v", path, open_err, allocator = allocator)
	}
	acquired, lock_err := platform_lock_file(file)
	if lock_err != nil {
		os.close(file)
		return {}, {}, errs.newf(.IO, "journal: cannot lock %s: %v", path, lock_err, allocator = allocator)
	}
	previous, previous_valid, has_content := read_previous_lock(file)
	result := Acquire_Result{previous = previous, previous_valid = previous_valid}
	if !acquired {
		os.close(file)
		result.state = .Active
		return {}, result, {}
	}
	result.state = .Acquired_Stale if has_content else .Acquired_New
	record := Lock_Record{
		pid = u64(os.get_pid()),
		session_id = session_id,
		process_instance_id = process_instance_id,
		created_unix_ns = now_unix_ns,
		heartbeat_unix_ns = now_unix_ns,
	}
	if write_err := write_lock_record(file, record); write_err != nil {
		platform_unlock_file(file)
		os.close(file)
		return {}, {}, errs.newf(.IO, "journal: cannot write session lock %s: %v", path, write_err, allocator = allocator)
	}
	return Session_Lock{file = file, record = record, allocator = allocator}, result, {}
}

// lock_heartbeat refreshes diagnostic time metadata. It does not extend or
// revalidate the OS lock; the continuously held handle already does that.
lock_heartbeat :: proc(lock: ^Session_Lock, now_unix_ns: i64) -> errs.Error {
	if lock == nil || lock.file == nil {
		return errs.new(.Invalid_Input, "journal: session lock is not open")
	}
	lock.record.heartbeat_unix_ns = now_unix_ns
	if err := write_lock_record(lock.file, lock.record); err != nil {
		return errs.newf(.IO, "journal: cannot refresh session lock: %v", err, allocator = lock.allocator)
	}
	return {}
}

// lock_release unlocks and closes exactly once, without deleting the lock file.
// Close still releases the OS lock if explicit unlock reports an error.
lock_release :: proc(lock: ^Session_Lock) -> errs.Error {
	if lock == nil || lock.file == nil {
		return {}
	}
	file := lock.file
	allocator := lock.allocator
	lock^ = Session_Lock{}
	unlock_err := platform_unlock_file(file)
	close_err := os.close(file)
	if unlock_err != nil {
		return errs.newf(.IO, "journal: cannot unlock session: %v", unlock_err, allocator = allocator)
	}
	if close_err != nil {
		return errs.newf(.IO, "journal: cannot close session lock: %v", close_err, allocator = allocator)
	}
	return {}
}
