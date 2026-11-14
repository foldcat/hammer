package journal

import "base:runtime"
import "core:os"

import errs "../errs"

// Operation_Hooks is an optional synchronous OS/fault-injection boundary.
// Nil fields use the real operation. Hooks must preserve the real write/sync
// contracts and are never retained beyond the Writer lifetime.
Operation_Hooks :: struct {
	data:  rawptr,
	write: proc(data: rawptr, file: ^os.File, bytes: []byte) -> (int, os.Error),
	sync:  proc(data: rawptr, file: ^os.File) -> os.Error,
}

// Writer owns one exclusively created journal file. It is not thread-safe.
// After any append or sync failure it is poisoned: close it and replay the
// valid prefix rather than appending behind a potentially partial record.
Writer :: struct {
	file:          ^os.File,
	next_sequence: u64,
	bytes_written: i64,
	record_count:  int,
	flush:         Flush_Policy,
	limits:        Limits,
	operations:    ^Operation_Hooks,
	failed:        bool,
	allocator:     runtime.Allocator,
}

operation_write :: proc(hooks: ^Operation_Hooks, file: ^os.File, data: []byte) -> (int, os.Error) {
	if hooks != nil && hooks.write != nil {
		return hooks.write(hooks.data, file, data)
	}
	return os.write(file, data)
}

operation_sync :: proc(hooks: ^Operation_Hooks, file: ^os.File) -> os.Error {
	if hooks != nil && hooks.sync != nil {
		return hooks.sync(hooks.data, file)
	}
	return os.sync(file)
}

write_all :: proc(file: ^os.File, hooks: ^Operation_Hooks, data: []byte) -> os.Error {
	remaining := data
	for len(remaining) > 0 {
		n, err := operation_write(hooks, file, remaining)
		if err != nil {
			return err
		}
		if n <= 0 || n > len(remaining) {
			return os.General_Error.Invalid_File
		}
		remaining = remaining[n:]
	}
	return nil
}

validate_create_header :: proc(header: Header, limits: Limits, allocator: runtime.Allocator) -> errs.Error {
	if len(header.path) > limits.max_path_bytes {
		return errs.newf(.Resource_Limit, "journal: path exceeds %d-byte limit", limits.max_path_bytes, allocator = allocator)
	}
	if header.stamp.id.kind < .None || header.stamp.id.kind > .Windows ||
		header.encoding.encoding < .UTF8 || header.encoding.encoding > .UTF32_BE ||
		header.encoding.bom < .None || header.encoding.bom > .UTF32_BE ||
		header.encoding.newline < .Unknown || header.encoding.newline > .Mixed ||
		header.stamp.mtime_nsec >= 1_000_000_000 ||
		header.encoding.newlines.lf < 0 || header.encoding.newlines.crlf < 0 || header.encoding.newlines.cr < 0 {
		return errs.newf(.Invalid_Input, "journal: invalid header metadata", allocator = allocator)
	}
	return {}
}

// create exclusively creates path and writes a complete synced header under
// the default flush policy. It never overwrites an existing journal. The
// header path is borrowed only for the synchronous call.
create :: proc(
	path: string,
	header: Header,
	options: Options,
	allocator := context.allocator,
) -> (writer: Writer, err: errs.Error) {
	if path == "" {
		return {}, errs.newf(.Invalid_Input, "journal: empty journal path", allocator = allocator)
	}
	if !limits_valid(options.limits) {
		return {}, errs.newf(.Invalid_Input, "journal: negative replay/write limit", allocator = allocator)
	}
	writer.limits = normalized_limits(options.limits)
	writer.flush = options.flush
	writer.operations = options.operations
	writer.allocator = allocator
	if err = validate_create_header(header, writer.limits, allocator); !errs.ok(err) {
		return {}, err
	}
	header_bytes := i64(HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE) + i64(len(header.path))
	if header_bytes > writer.limits.max_file_bytes {
		return {}, errs.newf(.Resource_Limit, "journal: header exceeds the configured file limit", allocator = allocator)
	}
	writer.bytes_written = header_bytes
	file, open_err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if open_err != nil {
		if open_err == .Exist {
			return {}, errs.newf(.Conflict, "journal: %s already exists", path, allocator = allocator)
		}
		return {}, errs.newf(.IO, "journal: cannot create %s: %v", path, open_err, allocator = allocator)
	}
	writer.file = file
	defer if !errs.ok(err) {
		os.close(file)
		os.remove(path)
		writer = Writer{}
	}

	fixed: [HEADER_FIXED_SIZE]u8
	encode_header_fixed(fixed[:], header, u32(len(header.path)))
	if write_err := write_all(file, options.operations, fixed[:]); write_err != nil {
		return {}, errs.newf(.IO, "journal: cannot write header to %s: %v", path, write_err, allocator = allocator)
	}
	if write_err := write_all(file, options.operations, transmute([]byte)header.path); write_err != nil {
		return {}, errs.newf(.IO, "journal: cannot write path to %s: %v", path, write_err, allocator = allocator)
	}
	trailer: [HEADER_TRAILER_SIZE]u8
	put_u32(trailer[:], 0, header_checksum(fixed[:], header.path))
	if write_err := write_all(file, options.operations, trailer[:]); write_err != nil {
		return {}, errs.newf(.IO, "journal: cannot write header checksum to %s: %v", path, write_err, allocator = allocator)
	}
	if options.flush == .Sync {
		if sync_err := operation_sync(options.operations, file); sync_err != nil {
			return {}, errs.newf(.IO, "journal: cannot sync header %s: %v", path, sync_err, allocator = allocator)
		}
	}
	writer.next_sequence = 1
	return writer, {}
}

// writer_append writes sequence/timestamp/payload as one checksummed record.
// The caller supplies the timestamp; sequence must equal writer.next_sequence.
// Success with flush=None means written, not durably flushed.
writer_append :: proc(writer: ^Writer, sequence: u64, timestamp_unix_ns: i64, payload: []byte) -> errs.Error {
	if writer == nil || writer.file == nil {
		return errs.new(.Invalid_Input, "journal: writer is not open")
	}
	allocator := writer.allocator
	if writer.failed {
		return errs.newf(.Conflict, "journal: writer is poisoned by an earlier I/O failure", allocator = allocator)
	}
	if sequence == 0 || sequence != writer.next_sequence {
		return errs.newf(
			.Conflict,
			"journal: sequence %d does not equal next sequence %d",
			sequence,
			writer.next_sequence,
			allocator = allocator,
		)
	}
	if len(payload) > writer.limits.max_payload_bytes {
		return errs.newf(
			.Resource_Limit,
			"journal: payload exceeds %d-byte limit",
			writer.limits.max_payload_bytes,
			allocator = allocator,
		)
	}
	if writer.record_count >= writer.limits.max_records {
		return errs.newf(.Resource_Limit, "journal: record limit reached", allocator = allocator)
	}
	record_bytes := i64(RECORD_HEADER_SIZE + RECORD_TRAILER_SIZE) + i64(len(payload))
	if record_bytes > writer.limits.max_file_bytes - writer.bytes_written {
		return errs.newf(.Resource_Limit, "journal: file size limit reached", allocator = allocator)
	}

	header: [RECORD_HEADER_SIZE]u8
	encode_record_header(header[:], sequence, timestamp_unix_ns, u32(len(payload)))
	trailer: [RECORD_TRAILER_SIZE]u8
	put_u32(trailer[:], 0, record_checksum(header[:], payload))
	write_err := write_all(writer.file, writer.operations, header[:])
	if write_err == nil {
		write_err = write_all(writer.file, writer.operations, payload)
	}
	if write_err == nil {
		write_err = write_all(writer.file, writer.operations, trailer[:])
	}
	if write_err != nil {
		writer.failed = true
		return errs.newf(.IO, "journal: cannot append record %d: %v", sequence, write_err, allocator = allocator)
	}
	writer.bytes_written += record_bytes
	writer.record_count += 1
	if sequence == max(u64) {
		writer.next_sequence = 0
	} else {
		writer.next_sequence = sequence + 1
	}
	if writer.flush == .Sync {
		if sync_err := operation_sync(writer.operations, writer.file); sync_err != nil {
			writer.failed = true
			return errs.newf(.IO, "journal: cannot sync record %d: %v", sequence, sync_err, allocator = allocator)
		}
	}
	return {}
}

writer_sync :: proc(writer: ^Writer) -> errs.Error {
	if writer == nil || writer.file == nil {
		return errs.new(.Invalid_Input, "journal: writer is not open")
	}
	if writer.failed {
		return errs.newf(.Conflict, "journal: writer is poisoned by an earlier I/O failure", allocator = writer.allocator)
	}
	if err := operation_sync(writer.operations, writer.file); err != nil {
		writer.failed = true
		return errs.newf(.IO, "journal: cannot sync: %v", err, allocator = writer.allocator)
	}
	return {}
}

// writer_close releases the file even when close reports an error. It does not
// imply a sync; call writer_sync first when durability is required.
writer_close :: proc(writer: ^Writer) -> errs.Error {
	if writer == nil || writer.file == nil {
		return {}
	}
	file := writer.file
	allocator := writer.allocator
	writer^ = Writer{}
	if err := os.close(file); err != nil {
		return errs.newf(.IO, "journal: cannot close: %v", err, allocator = allocator)
	}
	return {}
}

replay_destroy :: proc(replay: ^Replay) {
	if replay == nil {
		return
	}
	allocator := replay.allocator
	if allocator.procedure != nil {
		for record in replay.records {
			delete(record.payload, allocator)
		}
		delete(replay.records)
		if replay.header.path != "" {
			delete(replay.header.path, allocator)
		}
	}
	replay^ = Replay{}
}

read_error :: proc(path: string, err: os.Error, allocator: runtime.Allocator) -> errs.Error {
	return errs.newf(.IO, "journal: cannot read %s: %v", path, err, allocator = allocator)
}

// replay returns every complete verified record before the first bad or torn
// record. Record-level corruption and budget stops are reported in status, not
// as fatal errors; the valid prefix remains owned by the caller. Invalid or
// torn file headers and OS failures return an error and no retained result.
replay :: proc(path: string, limits: Limits, allocator := context.allocator) -> (result: Replay, err: errs.Error) {
	owned: Replay
	if path == "" {
		return {}, errs.newf(.Invalid_Input, "journal: empty journal path", allocator = allocator)
	}
	if !limits_valid(limits) {
		return {}, errs.newf(.Invalid_Input, "journal: negative replay limit", allocator = allocator)
	}
	bounds := normalized_limits(limits)
	owned.allocator = allocator
	owned.records = make([dynamic]Record, allocator)
	defer if !errs.ok(err) {
		replay_destroy(&owned)
	}

	file, open_err := os.open(path, {.Read})
	if open_err != nil {
		return {}, errs.newf(.IO, "journal: cannot open %s: %v", path, open_err, allocator = allocator)
	}
	defer os.close(file)
	file_size, size_err := os.file_size(file)
	if size_err != nil || file_size < 0 {
		return {}, errs.newf(.IO, "journal: cannot determine size of %s: %v", path, size_err, allocator = allocator)
	}
	if file_size < HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE {
		return {}, errs.newf(.Invalid_Input, "journal: %s has a torn header", path, allocator = allocator)
	}

	fixed: [HEADER_FIXED_SIZE]u8
	if _, read_err := os.read_full(file, fixed[:]); read_err != nil {
		return {}, read_error(path, read_err, allocator)
	}
	header, path_length, header_ok := decode_header_fixed(fixed[:])
	if !header_ok {
		return {}, errs.newf(.Invalid_Input, "journal: %s has an invalid header", path, allocator = allocator)
	}
	if get_u32(fixed[:], 12) != FORMAT_VERSION {
		return {}, errs.newf(.Unsupported, "journal: %s uses unsupported format version", path, allocator = allocator)
	}
	if int(path_length) > bounds.max_path_bytes {
		return {}, errs.newf(.Resource_Limit, "journal: %s path exceeds the configured limit", path, allocator = allocator)
	}
	header_bytes := i64(HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE) + i64(path_length)
	if header_bytes > file_size {
		return {}, errs.newf(.Invalid_Input, "journal: %s has a torn header", path, allocator = allocator)
	}
	if header_bytes > bounds.max_file_bytes {
		return {}, errs.newf(.Resource_Limit, "journal: %s header exceeds the configured file limit", path, allocator = allocator)
	}
	path_bytes, alloc_err := make([]byte, int(path_length), allocator)
	if alloc_err != .None {
		return {}, errs.newf(.Resource_Limit, "journal: allocating path failed: %v", alloc_err, allocator = allocator)
	}
	owned.header = header
	owned.header.path = string(path_bytes)
	if int(path_length) > 0 {
		if _, read_err := os.read_full(file, path_bytes); read_err != nil {
			return {}, read_error(path, read_err, allocator)
		}
	}
	trailer: [HEADER_TRAILER_SIZE]u8
	if _, read_err := os.read_full(file, trailer[:]); read_err != nil {
		return {}, read_error(path, read_err, allocator)
	}
	if get_u32(trailer[:], 0) != header_checksum(fixed[:], owned.header.path) {
		return {}, errs.newf(.Invalid_Input, "journal: %s header checksum mismatch", path, allocator = allocator)
	}
	owned.valid_bytes = header_bytes
	next_sequence := u64(1)

	for owned.valid_bytes < file_size {
		remaining := file_size - owned.valid_bytes
		if owned.valid_bytes >= bounds.max_file_bytes {
			owned.status = .File_Limit
			return owned, {}
		}
		if len(owned.records) >= bounds.max_records {
			owned.status = .Record_Limit
			return owned, {}
		}
		if bounds.max_file_bytes - owned.valid_bytes < RECORD_HEADER_SIZE {
			owned.status = .File_Limit
			return owned, {}
		}
		if remaining < RECORD_HEADER_SIZE {
			owned.status = .Torn_Record
			return owned, {}
		}
		record_header: [RECORD_HEADER_SIZE]u8
		if _, read_err := os.read_full(file, record_header[:]); read_err != nil {
			return {}, read_error(path, read_err, allocator)
		}
		decoded := decode_record_header(record_header[:])
		if decoded.version != RECORD_VERSION {
			owned.status = .Unsupported_Record_Version
			return owned, {}
		}
		if next_sequence == 0 || decoded.sequence != next_sequence {
			owned.status = .Sequence_Mismatch
			return owned, {}
		}
		if u64(decoded.payload_length) > u64(bounds.max_payload_bytes) {
			owned.status = .Payload_Limit
			return owned, {}
		}
		record_bytes := i64(RECORD_HEADER_SIZE + RECORD_TRAILER_SIZE) + i64(decoded.payload_length)
		if record_bytes > remaining {
			owned.status = .Torn_Record
			return owned, {}
		}
		if record_bytes > bounds.max_file_bytes - owned.valid_bytes {
			owned.status = .File_Limit
			return owned, {}
		}
		payload, payload_err := make([]byte, int(decoded.payload_length), allocator)
		if payload_err != .None {
			return {}, errs.newf(.Resource_Limit, "journal: allocating record payload failed: %v", payload_err, allocator = allocator)
		}
		if len(payload) > 0 {
			if _, read_err := os.read_full(file, payload); read_err != nil {
				delete(payload, allocator)
				return {}, read_error(path, read_err, allocator)
			}
		}
		if _, read_err := os.read_full(file, trailer[:]); read_err != nil {
			delete(payload, allocator)
			return {}, read_error(path, read_err, allocator)
		}
		if get_u32(trailer[:], 0) != record_checksum(record_header[:], payload) {
			delete(payload, allocator)
			owned.status = .Checksum_Mismatch
			return owned, {}
		}
		_, append_err := append(&owned.records, Record {
			sequence = decoded.sequence,
			timestamp_unix_ns = decoded.timestamp_unix_ns,
			payload = payload,
		})
		if append_err != .None {
			delete(payload, allocator)
			return {}, errs.newf(.Resource_Limit, "journal: growing replay result failed: %v", append_err, allocator = allocator)
		}
		owned.valid_bytes += record_bytes
		if next_sequence == max(u64) {
			next_sequence = 0
		} else {
			next_sequence += 1
		}
	}
	owned.status = .Complete
	return owned, {}
}
