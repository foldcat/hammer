// Package journal implements versioned recovery journals, checkpoints, and
// generation rotation (M04.01–M04.02, SPECS.md §11.3–§11.5). Transaction
// payloads are opaque; serialization and buffer application are separate.
package journal

import "base:runtime"
import "core:crypto/sha2"

import filecodec "../filecodec"
import fileid "../fileid"

FORMAT_VERSION :: u32(2)
RECORD_VERSION :: u32(1)
BASE_HASH_SIZE :: sha2.DIGEST_SIZE_256

DEFAULT_MAX_PATH_BYTES :: 4096
DEFAULT_MAX_PAYLOAD_BYTES :: 1024 * 1024
DEFAULT_MAX_RECORDS :: 65536
DEFAULT_MAX_FILE_BYTES :: i64(64 * 1024 * 1024)

// Limits bound every variable-length input and replay result. A zero field
// selects its default; negative values are invalid.
Limits :: struct {
	max_path_bytes:    int,
	max_payload_bytes: int,
	max_records:       int,
	max_file_bytes:    i64,
}

// Header is the file/content identity and session metadata for one journal.
// On create, path is borrowed for the call. On replay, Replay owns it.
Header :: struct {
	path:                string,
	stamp:               fileid.File_Stamp,
	base_hash:           [BASE_HASH_SIZE]u8,
	encoding:            filecodec.Metadata,
	session_id:          u64,
	process_instance_id: u64,
	generation:          u64,
	created_unix_ns:     i64,
}

// Record is one verified transaction payload. Replay owns payload.
Record :: struct {
	sequence:         u64,
	timestamp_unix_ns: i64,
	payload:          []byte,
}

// Replay_Status describes why replay stopped. Every status other than
// Complete leaves valid_bytes immediately after the last verified record.
Replay_Status :: enum {
	Complete,
	Torn_Record,
	Payload_Limit,
	Record_Limit,
	File_Limit,
	Unsupported_Record_Version,
	Sequence_Mismatch,
	Checksum_Mismatch,
}

// Replay owns header.path, every record payload, and the records array.
// Pass by pointer and release with replay_destroy; do not deep-copy it.
Replay :: struct {
	header:      Header,
	records:     [dynamic]Record,
	valid_bytes: i64,
	status:      Replay_Status,
	allocator:   runtime.Allocator,
}

// Flush_Policy distinguishes a completed write from an explicitly synced one.
// Sync is the safe zero value. None requires an explicit writer_sync before a
// durability acknowledgment or clean shutdown.
Flush_Policy :: enum {
	Sync,
	None,
}

// Options fields are copied by create. Operation hooks, when supplied, are
// borrowed and must remain alive until writer_close.
Options :: struct {
	flush:      Flush_Policy,
	limits:     Limits,
	operations: ^Operation_Hooks,
}

// Identity_Status is the strict base-file validation result. Recovery callers
// must require Match before applying transaction records to disk-backed text.
Identity_Status :: enum {
	Match,
	Path_Mismatch,
	Base_Hash_Mismatch,
	File_Replaced,
	File_Modified,
	Identity_Unverified,
}

normalized_limits :: proc(limits: Limits) -> Limits {
	out := limits
	if out.max_path_bytes == 0 {
		out.max_path_bytes = DEFAULT_MAX_PATH_BYTES
	}
	if out.max_payload_bytes == 0 {
		out.max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES
	}
	if out.max_records == 0 {
		out.max_records = DEFAULT_MAX_RECORDS
	}
	if out.max_file_bytes == 0 {
		out.max_file_bytes = DEFAULT_MAX_FILE_BYTES
	}
	return out
}

limits_valid :: proc(limits: Limits) -> bool {
	return limits.max_path_bytes >= 0 &&
		limits.max_payload_bytes >= 0 &&
		limits.max_records >= 0 &&
		limits.max_file_bytes >= 0
}

hash_base :: proc(content: []byte) -> [BASE_HASH_SIZE]u8 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, content)
	digest: [BASE_HASH_SIZE]u8
	sha2.final(&ctx, digest[:])
	return digest
}

// validate_identity compares the exact path, base content hash, platform file
// identity, and recorded file version. Identity-less filesystems require an
// explicit opt-in and still need matching path, content hash, size, and mtime.
validate_identity :: proc(
	header: Header,
	observed_path: string,
	observed_stamp: fileid.File_Stamp,
	observed_hash: [BASE_HASH_SIZE]u8,
	allow_unverified_identity := false,
) -> Identity_Status {
	if header.path != observed_path {
		return .Path_Mismatch
	}
	if header.base_hash != observed_hash {
		return .Base_Hash_Mismatch
	}
	if !fileid.stamp_identity_verified(header.stamp, observed_stamp) {
		if !allow_unverified_identity {
			return .Identity_Unverified
		}
	} else if !fileid.id_equal(header.stamp.id, observed_stamp.id) {
		return .File_Replaced
	}
	if !fileid.version_equal(header.stamp, observed_stamp) {
		return .File_Modified
	}
	return .Match
}
