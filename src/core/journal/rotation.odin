package journal

import errs "../errs"

DEFAULT_ROTATION_INTERVAL_NS :: i64(30 * 1_000_000_000)
DEFAULT_ROTATION_BYTES :: i64(8 * 1024 * 1024)
DEFAULT_ROTATION_RECORDS :: 4096

// Rotation_Policy is evaluated by the caller; no clock thread or scheduler is
// introduced. Zero fields select defaults. Negative values disable rotation.
Rotation_Policy :: struct {
	interval_ns:      i64,
	max_journal_bytes: i64,
	max_records:      int,
}

normalized_rotation_policy :: proc(policy: Rotation_Policy) -> Rotation_Policy {
	out := policy
	if out.interval_ns == 0 {
		out.interval_ns = DEFAULT_ROTATION_INTERVAL_NS
	}
	if out.max_journal_bytes == 0 {
		out.max_journal_bytes = DEFAULT_ROTATION_BYTES
	}
	if out.max_records == 0 {
		out.max_records = DEFAULT_ROTATION_RECORDS
	}
	return out
}

rotation_due :: proc(writer: ^Writer, last_checkpoint_unix_ns, now_unix_ns: i64, policy: Rotation_Policy) -> bool {
	if writer == nil || writer.file == nil || writer.failed {
		return false
	}
	bounds := normalized_rotation_policy(policy)
	if bounds.interval_ns < 0 || bounds.max_journal_bytes < 0 || bounds.max_records < 0 {
		return false
	}
	if writer.bytes_written >= bounds.max_journal_bytes || writer.record_count >= bounds.max_records {
		return true
	}
	return now_unix_ns >= last_checkpoint_unix_ns &&
		u64(now_unix_ns) - u64(last_checkpoint_unix_ns) >= u64(bounds.interval_ns)
}

// rotate publishes a complete checkpoint and matching empty next-generation
// journal before closing the current writer or removing old files. The new
// generation must be greater than the current generation. Old paths may be
// empty only for the initial generation without a checkpoint.
//
// A false result means the current writer is unchanged and remains usable.
// A true result means current now owns the new writer even when err reports a
// post-publication close/cleanup failure. Old files are removed only after the
// new pair is complete; cleanup failure never rolls back the new generation.
rotate :: proc(
	current: ^Writer,
	old_checkpoint_path, old_journal_path: string,
	new_checkpoint_path, new_journal_path: string,
	new_header: Header,
	snapshot: []byte,
	allocator := context.allocator,
) -> (bool, errs.Error) {
	if current == nil || current.file == nil {
		return false, errs.newf(.Invalid_Input, "journal: rotation requires an open writer", allocator = allocator)
	}
	if current.failed {
		return false, errs.newf(.Conflict, "journal: cannot rotate a poisoned writer", allocator = allocator)
	}
	if new_header.generation <= current.generation {
		return false, errs.newf(.Conflict, "journal: next generation must increase", allocator = allocator)
	}
	options := Options {
		flush = current.flush,
		limits = current.limits,
		operations = current.operations,
	}
	next, create_err := create(new_journal_path, new_header, options, allocator)
	if !errs.ok(create_err) {
		return false, create_err
	}
	checkpoint_err := write_checkpoint(new_checkpoint_path, new_header, snapshot, options, allocator)
	if !errs.ok(checkpoint_err) {
		close_err := writer_close(&next)
		if !errs.ok(close_err) {
			errs.destroy(&close_err)
		}
		operation_remove(current.operations, new_journal_path)
		return false, checkpoint_err
	}

	close_err := writer_close(current)
	current^ = next
	old_paths := []string{old_checkpoint_path, old_journal_path}
	for path in old_paths {
		if path == "" {
			continue
		}
		remove_err := operation_remove(current.operations, path)
		if remove_err == nil || remove_err == .Not_Exist {
			continue
		}
		if errs.ok(close_err) {
			close_err = errs.newf(.IO, "journal: cannot remove old generation %s: %v", path, remove_err, allocator = allocator)
		}
	}
	return true, close_err
}
