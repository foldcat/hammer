package journal

import "base:runtime"
import "core:hash"
import "core:os"
import "core:strings"

import errs "../errs"
import fileid "../fileid"

CHECKPOINT_VERSION :: u32(1)
CHECKPOINT_FIXED_SIZE :: 64
CHECKPOINT_TRAILER_SIZE :: 4
CHECKPOINT_MAGIC :: [8]u8{'H', 'M', 'C', 'P', '\r', '\n', 0x1a, '\n'}

// Checkpoint is an all-or-nothing full snapshot plus the original file/base
// identity. The header and snapshot are owned; release with checkpoint_destroy.
Checkpoint :: struct {
	header:    Header,
	snapshot:  []byte,
	allocator: runtime.Allocator,
}

// Generation pairs a checkpoint with its matching tail journal. Both members
// are owned and must remain at fixed locations until generation_destroy.
Generation :: struct {
	checkpoint: Checkpoint,
	tail:       Replay,
}

checkpoint_destroy :: proc(checkpoint: ^Checkpoint) {
	if checkpoint == nil {
		return
	}
	allocator := checkpoint.allocator
	if allocator.procedure != nil {
		delete(checkpoint.snapshot, allocator)
		if checkpoint.header.path != "" {
			delete(checkpoint.header.path, allocator)
		}
	}
	checkpoint^ = Checkpoint{}
}

generation_destroy :: proc(generation: ^Generation) {
	if generation == nil {
		return
	}
	checkpoint_destroy(&generation.checkpoint)
	replay_destroy(&generation.tail)
	generation^ = Generation{}
}

decode_embedded_header :: proc(data: []byte) -> (header: Header, ok: bool) {
	if len(data) < HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE {
		return {}, false
	}
	fixed := data[:HEADER_FIXED_SIZE]
	decoded, path_length, valid := decode_header_fixed(fixed)
	if !valid || get_u32(fixed, 12) != FORMAT_VERSION {
		return {}, false
	}
	expected := HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE + int(path_length)
	if len(data) != expected {
		return {}, false
	}
	decoded.path = string(data[HEADER_FIXED_SIZE:HEADER_FIXED_SIZE + int(path_length)])
	if get_u32(data[expected - HEADER_TRAILER_SIZE:], 0) != header_checksum(fixed, decoded.path) {
		return {}, false
	}
	return decoded, true
}

header_equal :: proc(a, b: Header) -> bool {
	return a.path == b.path &&
		fileid.stamp_equal(a.stamp, b.stamp) &&
		a.base_hash == b.base_hash &&
		a.encoding == b.encoding &&
		a.session_id == b.session_id &&
		a.process_instance_id == b.process_instance_id &&
		a.generation == b.generation &&
		a.created_unix_ns == b.created_unix_ns
}

// write_checkpoint exclusively creates one complete checkpoint. Existing files
// are never overwritten. Errors before successful close remove only the new
// file; the previous generation is not touched.
write_checkpoint :: proc(
	path: string,
	header: Header,
	snapshot: []byte,
	options: Options,
	allocator := context.allocator,
) -> (err: errs.Error) {
	if path == "" {
		return errs.newf(.Invalid_Input, "journal: empty checkpoint path", allocator = allocator)
	}
	if !limits_valid(options.limits) {
		return errs.newf(.Invalid_Input, "journal: negative checkpoint limit", allocator = allocator)
	}
	bounds := normalized_limits(options.limits)
	if err = validate_create_header(header, bounds, allocator); !errs.ok(err) {
		return err
	}
	header_bytes := i64(HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE) + i64(len(header.path))
	fixed_bytes := i64(CHECKPOINT_FIXED_SIZE + CHECKPOINT_TRAILER_SIZE) + header_bytes
	if fixed_bytes > bounds.max_file_bytes || i64(len(snapshot)) > bounds.max_file_bytes - fixed_bytes {
		return errs.newf(.Resource_Limit, "journal: checkpoint exceeds the configured file limit", allocator = allocator)
	}

	file, open_err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if open_err != nil {
		if open_err == .Exist {
			return errs.newf(.Conflict, "journal: checkpoint %s already exists", path, allocator = allocator)
		}
		return errs.newf(.IO, "journal: cannot create checkpoint %s: %v", path, open_err, allocator = allocator)
	}
	published := false
	closed := false
	defer if !published {
		operation_remove(options.operations, path)
	}
	defer if !closed {
		operation_close(options.operations, file)
	}

	fixed: [CHECKPOINT_FIXED_SIZE]u8
	magic := CHECKPOINT_MAGIC
	copy(fixed[:len(magic)], magic[:])
	put_u32(fixed[:], 8, CHECKPOINT_VERSION)
	put_u32(fixed[:], 12, u32(header_bytes))
	put_u64(fixed[:], 16, u64(len(snapshot)))
	snapshot_hash := hash_base(snapshot)
	copy(fixed[24:56], snapshot_hash[:])
	put_u64(fixed[:], 56, 0)
	journal_fixed: [HEADER_FIXED_SIZE]u8
	encode_header_fixed(journal_fixed[:], header, u32(len(header.path)))
	journal_trailer: [HEADER_TRAILER_SIZE]u8
	put_u32(journal_trailer[:], 0, header_checksum(journal_fixed[:], header.path))
	trailer: [CHECKPOINT_TRAILER_SIZE]u8

	if write_err := write_all(file, options.operations, fixed[:]); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint header %s: %v", path, write_err, allocator = allocator)
	}
	if write_err := write_all(file, options.operations, journal_fixed[:]); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint identity %s: %v", path, write_err, allocator = allocator)
	}
	if write_err := write_all(file, options.operations, transmute([]byte)header.path); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint path %s: %v", path, write_err, allocator = allocator)
	}
	if write_err := write_all(file, options.operations, journal_trailer[:]); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint identity checksum %s: %v", path, write_err, allocator = allocator)
	}
	if write_err := write_all(file, options.operations, snapshot); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint snapshot %s: %v", path, write_err, allocator = allocator)
	}
	// The whole-file checksum includes every embedded journal-header byte.
	crc := hash.crc32(fixed[:])
	crc = hash.crc32(journal_fixed[:], crc)
	crc = hash.crc32(transmute([]byte)header.path, crc)
	crc = hash.crc32(journal_trailer[:], crc)
	crc = hash.crc32(snapshot, crc)
	put_u32(trailer[:], 0, crc)
	if write_err := write_all(file, options.operations, trailer[:]); write_err != nil {
		return errs.newf(.IO, "journal: cannot write checkpoint checksum %s: %v", path, write_err, allocator = allocator)
	}
	if options.flush == .Sync {
		if sync_err := operation_sync(options.operations, file); sync_err != nil {
			return errs.newf(.IO, "journal: cannot sync checkpoint %s: %v", path, sync_err, allocator = allocator)
		}
	}
	if close_err := operation_close(options.operations, file); close_err != nil {
		closed = true
		return errs.newf(.IO, "journal: cannot close checkpoint %s: %v", path, close_err, allocator = allocator)
	}
	closed = true
	published = true
	return {}
}

// read_checkpoint requires a complete exact-length file. Unlike journal replay,
// there is no valid-prefix snapshot: any torn or corrupt checkpoint is rejected.
read_checkpoint :: proc(path: string, limits: Limits, allocator := context.allocator) -> (result: Checkpoint, err: errs.Error) {
	owned: Checkpoint
	if path == "" {
		return {}, errs.newf(.Invalid_Input, "journal: empty checkpoint path", allocator = allocator)
	}
	if !limits_valid(limits) {
		return {}, errs.newf(.Invalid_Input, "journal: negative checkpoint limit", allocator = allocator)
	}
	bounds := normalized_limits(limits)
	owned.allocator = allocator
	defer if !errs.ok(err) {
		checkpoint_destroy(&owned)
	}

	file, open_err := os.open(path, {.Read})
	if open_err != nil {
		return {}, errs.newf(.IO, "journal: cannot open checkpoint %s: %v", path, open_err, allocator = allocator)
	}
	defer os.close(file)
	file_size, size_err := os.file_size(file)
	if size_err != nil || file_size < 0 {
		return {}, errs.newf(.IO, "journal: cannot determine checkpoint size %s: %v", path, size_err, allocator = allocator)
	}
	if file_size < CHECKPOINT_FIXED_SIZE + CHECKPOINT_TRAILER_SIZE {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s has a torn header", path, allocator = allocator)
	}
	if file_size > bounds.max_file_bytes {
		return {}, errs.newf(.Resource_Limit, "journal: checkpoint %s exceeds the configured file limit", path, allocator = allocator)
	}
	fixed: [CHECKPOINT_FIXED_SIZE]u8
	if _, read_err := os.read_full(file, fixed[:]); read_err != nil {
		return {}, read_error(path, read_err, allocator)
	}
	magic := CHECKPOINT_MAGIC
	for i in 0 ..< len(magic) {
		if fixed[i] != magic[i] {
			return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s has invalid magic", path, allocator = allocator)
		}
	}
	if get_u32(fixed[:], 8) != CHECKPOINT_VERSION {
		return {}, errs.newf(.Unsupported, "journal: checkpoint %s uses an unsupported version", path, allocator = allocator)
	}
	if get_u64(fixed[:], 56) != 0 {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s has nonzero reserved fields", path, allocator = allocator)
	}
	header_bytes := get_u32(fixed[:], 12)
	snapshot_length := get_u64(fixed[:], 16)
	if header_bytes < HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s has an invalid embedded header", path, allocator = allocator)
	}
	expected_size := i64(CHECKPOINT_FIXED_SIZE + CHECKPOINT_TRAILER_SIZE) + i64(header_bytes)
	if snapshot_length > u64(max(i64)) || expected_size > file_size || i64(snapshot_length) > file_size - expected_size {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s length overflow", path, allocator = allocator)
	}
	expected_size += i64(snapshot_length)
	if expected_size != file_size {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s is torn or has trailing data", path, allocator = allocator)
	}
	embedded, embedded_err := make([]byte, int(header_bytes), allocator)
	if embedded_err != .None {
		return {}, errs.newf(.Resource_Limit, "journal: allocating checkpoint identity failed: %v", embedded_err, allocator = allocator)
	}
	defer delete(embedded, allocator)
	if _, read_err := os.read_full(file, embedded); read_err != nil {
		return {}, read_error(path, read_err, allocator)
	}
	header, header_ok := decode_embedded_header(embedded)
	if !header_ok {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s has an invalid identity", path, allocator = allocator)
	}
	if len(header.path) > bounds.max_path_bytes {
		return {}, errs.newf(.Resource_Limit, "journal: checkpoint %s path exceeds the configured limit", path, allocator = allocator)
	}
	owned.header = header
	owned.header.path, embedded_err = strings.clone(header.path, allocator)
	if embedded_err != .None {
		owned.header.path = ""
		return {}, errs.newf(.Resource_Limit, "journal: copying checkpoint path failed: %v", embedded_err, allocator = allocator)
	}
	owned.snapshot, embedded_err = make([]byte, int(snapshot_length), allocator)
	if embedded_err != .None {
		return {}, errs.newf(.Resource_Limit, "journal: allocating checkpoint snapshot failed: %v", embedded_err, allocator = allocator)
	}
	if len(owned.snapshot) > 0 {
		if _, read_err := os.read_full(file, owned.snapshot); read_err != nil {
			return {}, read_error(path, read_err, allocator)
		}
	}
	trailer: [CHECKPOINT_TRAILER_SIZE]u8
	if _, read_err := os.read_full(file, trailer[:]); read_err != nil {
		return {}, read_error(path, read_err, allocator)
	}
	crc := hash.crc32(fixed[:])
	crc = hash.crc32(embedded, crc)
	crc = hash.crc32(owned.snapshot, crc)
	if get_u32(trailer[:], 0) != crc {
		return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s checksum mismatch", path, allocator = allocator)
	}
	expected_hash := hash_base(owned.snapshot)
	for i in 0 ..< BASE_HASH_SIZE {
		if fixed[24 + i] != expected_hash[i] {
			return {}, errs.newf(.Invalid_Input, "journal: checkpoint %s snapshot hash mismatch", path, allocator = allocator)
		}
	}
	return owned, {}
}

// recover_generation validates that checkpoint and tail carry identical
// identity/session/generation metadata. A torn tail still returns its valid
// prefix; checkpoint corruption or a mismatched pair rejects the generation.
recover_generation :: proc(
	checkpoint_path, journal_path: string,
	limits: Limits,
	allocator := context.allocator,
) -> (Generation, errs.Error) {
	checkpoint, checkpoint_err := read_checkpoint(checkpoint_path, limits, allocator)
	if !errs.ok(checkpoint_err) {
		return {}, checkpoint_err
	}
	tail, tail_err := replay(journal_path, limits, allocator)
	if !errs.ok(tail_err) {
		checkpoint_destroy(&checkpoint)
		return {}, tail_err
	}
	if !header_equal(checkpoint.header, tail.header) {
		checkpoint_destroy(&checkpoint)
		replay_destroy(&tail)
		return {}, errs.newf(.Conflict, "journal: checkpoint and tail belong to different generations", allocator = allocator)
	}
	return Generation{checkpoint = checkpoint, tail = tail}, {}
}
