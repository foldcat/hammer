// Persistent undo transaction archives (M04.05).
//
// The archive reuses the journal's versioned, checksummed, bounded record
// container, but has its own files and retention lifetime. It never rotates or
// prunes recovery data. Each record is one applied undo-tree node in apply
// order. Parent IDs reconstruct child lists; roots are rebuilt by applying the
// archived operations through doc_apply against the verified base content.
package txn

import "core:encoding/endian"
import "core:time"

import errs "../errs"
import journal "../journal"
import rope "../rope"

ARCHIVE_ENTRY_VERSION :: u32(1)
ARCHIVE_ENTRY_FIXED_SIZE :: 128
ARCHIVE_OPERATION_SIZE :: 32

// Archive_Writer owns one undo archive. It is synchronous and not thread-safe.
// The journal writer's append/sync failure and poisoning rules apply unchanged.
Archive_Writer :: struct {
	writer: journal.Writer,
}

archive_create :: proc(
	path: string,
	header: journal.Header,
	options: journal.Options,
	allocator := context.allocator,
) -> (Archive_Writer, errs.Error) {
	writer, err := journal.create(path, header, options, allocator)
	return Archive_Writer{writer = writer}, err
}

archive_entry_size :: proc(entry: Log_Entry) -> (int, bool) {
	if len(entry.ops) > int(max(u32)) {
		return 0, false
	}
	size := u64(ARCHIVE_ENTRY_FIXED_SIZE)
	for op in entry.ops {
		data_length := 0
		switch o in op {
		case Insert:
			data_length = len(o.data)
		case Delete:
		case Replace:
			data_length = len(o.data)
		}
		if data_length > int(max(u32)) {
			return 0, false
		}
		size += u64(ARCHIVE_OPERATION_SIZE) + u64(data_length)
		if size > u64(max(int)) {
			return 0, false
		}
	}
	return int(size), true
}

archive_put_selection :: proc(data: []byte, offset: int, selection: Selection) {
	endian.put_i64(data[offset:], .Little, i64(selection.anchor))
	endian.put_i64(data[offset + 8:], .Little, i64(selection.active))
	endian.put_u32(data[offset + 16:], .Little, u32(selection.affinity))
	endian.put_u32(data[offset + 20:], .Little, 0)
	endian.put_f64(data[offset + 24:], .Little, selection.visual_column)
}

archive_get_selection :: proc(data: []byte, offset: int) -> Selection {
	anchor, _ := endian.get_i64(data[offset:], .Little)
	active, _ := endian.get_i64(data[offset + 8:], .Little)
	affinity, _ := endian.get_u32(data[offset + 16:], .Little)
	column, _ := endian.get_f64(data[offset + 24:], .Little)
	return Selection {
		anchor = int(anchor),
		active = int(active),
		affinity = Affinity(affinity),
		visual_column = column,
	}
}

// archive_encode_entry serializes one node with explicit little-endian fields.
// The returned payload is owned by the caller. Child IDs and roots are derived
// during replay and are not serialized.
archive_encode_entry :: proc(entry: Log_Entry, allocator := context.allocator) -> ([]byte, errs.Error) {
	size, valid := archive_entry_size(entry)
	if !valid {
		return {}, errs.newf(.Resource_Limit, "txn: archive entry is too large", allocator = allocator)
	}
	payload, alloc_err := make([]byte, size, allocator)
	if alloc_err != .None {
		return {}, errs.newf(.Resource_Limit, "txn: allocating archive entry failed: %v", alloc_err, allocator = allocator)
	}
	endian.put_u32(payload, .Little, ARCHIVE_ENTRY_VERSION)
	endian.put_u32(payload[4:], .Little, u32(len(entry.ops)))
	endian.put_u64(payload[8:], .Little, u64(entry.id))
	endian.put_u64(payload[16:], .Little, u64(entry.parent))
	endian.put_u64(payload[24:], .Little, entry.base)
	endian.put_u64(payload[32:], .Little, entry.after)
	endian.put_u64(payload[40:], .Little, entry.grouping_key)
	endian.put_i64(payload[48:], .Little, time.to_unix_nanoseconds(entry.timestamp))
	archive_put_selection(payload, 56, entry.before_selection)
	archive_put_selection(payload, 88, entry.after_selection)
	endian.put_u32(payload[120:], .Little, u32(entry.source))
	endian.put_u32(payload[124:], .Little, 0)

	offset := ARCHIVE_ENTRY_FIXED_SIZE
	for op in entry.ops {
		kind := u32(0)
		start := i64(0)
		end_pos := i64(0)
		data: []byte
		switch o in op {
		case Insert:
			kind = 1
			start = i64(o.pos)
			end_pos = i64(o.pos)
			data = o.data
		case Delete:
			kind = 2
			start = i64(o.range.start)
			end_pos = i64(o.range.end)
		case Replace:
			kind = 3
			start = i64(o.range.start)
			end_pos = i64(o.range.end)
			data = o.data
		}
		endian.put_u32(payload[offset:], .Little, kind)
		endian.put_u32(payload[offset + 4:], .Little, 0)
		endian.put_i64(payload[offset + 8:], .Little, start)
		endian.put_i64(payload[offset + 16:], .Little, end_pos)
		endian.put_u32(payload[offset + 24:], .Little, u32(len(data)))
		endian.put_u32(payload[offset + 28:], .Little, 0)
		copy(payload[offset + ARCHIVE_OPERATION_SIZE:], data)
		offset += ARCHIVE_OPERATION_SIZE + len(data)
	}
	return payload, {}
}

archive_decode_error :: proc(message: string, allocator := context.allocator) -> errs.Error {
	return errs.new(.Invalid_Input, message, allocator = allocator)
}

// archive_decode_entry validates and decodes one payload. The returned entry
// owns its operation/data copies; release them with ops_destroy. Its children
// and roots are empty until archive replay reconstructs them.
archive_decode_entry :: proc(
	payload: []byte,
	allocator := context.allocator,
) -> (result: Log_Entry, err: errs.Error) {
	owned: Log_Entry
	defer if !errs.ok(err) {
		ops_destroy(owned.ops, allocator)
	}
	if len(payload) < ARCHIVE_ENTRY_FIXED_SIZE {
		return {}, archive_decode_error("txn: archive entry has a torn fixed header", allocator)
	}
	version, _ := endian.get_u32(payload, .Little)
	if version != ARCHIVE_ENTRY_VERSION {
		return {}, errs.newf(.Unsupported, "txn: unsupported archive entry version %d", version, allocator = allocator)
	}
	reserved, _ := endian.get_u32(payload[124:], .Little)
	if reserved != 0 {
		return {}, archive_decode_error("txn: archive entry has nonzero reserved fields", allocator)
	}
	source, _ := endian.get_u32(payload[120:], .Little)
	if source > u32(Source.Recovery) {
		return {}, archive_decode_error("txn: archive entry has an invalid source", allocator)
	}
	before_affinity, _ := endian.get_u32(payload[72:], .Little)
	after_affinity, _ := endian.get_u32(payload[104:], .Little)
	before_reserved, _ := endian.get_u32(payload[76:], .Little)
	after_reserved, _ := endian.get_u32(payload[108:], .Little)
	if before_affinity > u32(Affinity.Right) || after_affinity > u32(Affinity.Right) {
		return {}, archive_decode_error("txn: archive entry has an invalid selection affinity", allocator)
	}
	if before_reserved != 0 || after_reserved != 0 {
		return {}, archive_decode_error("txn: archive selection has nonzero reserved fields", allocator)
	}
	operation_count, _ := endian.get_u32(payload[4:], .Little)
	if u64(operation_count) > u64(len(payload) - ARCHIVE_ENTRY_FIXED_SIZE) / ARCHIVE_OPERATION_SIZE {
		return {}, archive_decode_error("txn: archive operation count exceeds the payload", allocator)
	}

	owned.id = Transaction_ID(journal.get_u64(payload, 8))
	owned.parent = Transaction_ID(journal.get_u64(payload, 16))
	owned.base = journal.get_u64(payload, 24)
	owned.after = journal.get_u64(payload, 32)
	owned.grouping_key = journal.get_u64(payload, 40)
	owned.timestamp = time.from_nanoseconds(journal.get_i64(payload, 48))
	owned.before_selection = archive_get_selection(payload, 56)
	owned.after_selection = archive_get_selection(payload, 88)
	owned.source = Source(source)

	if operation_count > 0 {
		operations, alloc_err := make([]Operation, int(operation_count), allocator)
		if alloc_err != .None {
			return {}, errs.newf(.Resource_Limit, "txn: allocating archived operations failed: %v", alloc_err, allocator = allocator)
		}
		owned.ops = operations
	}
	offset := ARCHIVE_ENTRY_FIXED_SIZE
	for operation_index in 0 ..< int(operation_count) {
		kind, _ := endian.get_u32(payload[offset:], .Little)
		op_reserved, _ := endian.get_u32(payload[offset + 4:], .Little)
		data_length, _ := endian.get_u32(payload[offset + 24:], .Little)
		data_reserved, _ := endian.get_u32(payload[offset + 28:], .Little)
		if op_reserved != 0 || data_reserved != 0 {
			return {}, archive_decode_error("txn: archived operation has nonzero reserved fields", allocator)
		}
		offset += ARCHIVE_OPERATION_SIZE
		if u64(data_length) > u64(len(payload) - offset) {
			return {}, archive_decode_error("txn: archived operation data exceeds the payload", allocator)
		}
		start := journal.get_i64(payload, offset - ARCHIVE_OPERATION_SIZE + 8)
		end_pos := journal.get_i64(payload, offset - ARCHIVE_OPERATION_SIZE + 16)
		if start < i64(min(int)) || start > i64(max(int)) || end_pos < i64(min(int)) || end_pos > i64(max(int)) {
			return {}, archive_decode_error("txn: archived operation offset does not fit this platform", allocator)
		}
		data: []byte
		if data_length > 0 {
			data_bytes, data_err := make([]byte, int(data_length), allocator)
			if data_err != .None {
				return {}, errs.newf(.Resource_Limit, "txn: allocating archived operation data failed: %v", data_err, allocator = allocator)
			}
			data = data_bytes
			copy(data, payload[offset:offset + int(data_length)])
		}
		switch kind {
		case 1:
			if start != end_pos {
				delete(data, allocator)
				return {}, archive_decode_error("txn: archived insert has mismatched positions", allocator)
			}
			owned.ops[operation_index] = Operation(Insert{pos = int(start), data = data})
		case 2:
			if data_length != 0 {
				delete(data, allocator)
				return {}, archive_decode_error("txn: archived delete contains data", allocator)
			}
			owned.ops[operation_index] = Operation(Delete{range = rope.Byte_Range{int(start), int(end_pos)}})
		case 3:
			owned.ops[operation_index] = Operation(Replace {
				range = rope.Byte_Range{int(start), int(end_pos)},
				data = data,
			})
		case:
			delete(data, allocator)
			return {}, archive_decode_error("txn: archived operation has an unknown kind", allocator)
		}
		offset += int(data_length)
	}
	if offset != len(payload) {
		return {}, archive_decode_error("txn: archive entry has trailing data", allocator)
	}
	return owned, {}
}

// archive_append writes entry as the next dense transaction/sequence ID.
// The entry and all operation data are borrowed only for the call.
archive_append :: proc(writer: ^Archive_Writer, entry: Log_Entry) -> errs.Error {
	if writer == nil {
		return errs.new(.Invalid_Input, "txn: nil archive writer")
	}
	if u64(entry.id) != writer.writer.next_sequence {
		return errs.newf(
			.Conflict,
			"txn: archive transaction ID %d does not equal next sequence %d",
			entry.id,
			writer.writer.next_sequence,
			allocator = writer.writer.allocator,
		)
	}
	if entry.parent >= entry.id {
		return errs.newf(.Invalid_Input, "txn: cannot archive a transaction with an invalid parent", allocator = writer.writer.allocator)
	}
	effective := false
	for op in entry.ops {
		switch o in op {
		case Insert:
			if len(o.data) > 0 {
				effective = true
			}
		case Delete, Replace:
			effective = true
		}
	}
	if !effective {
		return errs.newf(.Invalid_Input, "txn: cannot archive a no-op transaction", allocator = writer.writer.allocator)
	}
	size, valid := archive_entry_size(entry)
	if !valid || size > writer.writer.limits.max_payload_bytes {
		return errs.newf(
			.Resource_Limit,
			"txn: archive entry exceeds the %d-byte payload limit",
			writer.writer.limits.max_payload_bytes,
			allocator = writer.writer.allocator,
		)
	}
	payload, encode_err := archive_encode_entry(entry, writer.writer.allocator)
	if !errs.ok(encode_err) {
		return encode_err
	}
	defer delete(payload, writer.writer.allocator)
	return journal.writer_append(
		&writer.writer,
		u64(entry.id),
		time.to_unix_nanoseconds(entry.timestamp),
		payload,
	)
}

archive_sync :: proc(writer: ^Archive_Writer) -> errs.Error {
	if writer == nil {
		return errs.new(.Invalid_Input, "txn: nil archive writer")
	}
	return journal.writer_sync(&writer.writer)
}

archive_close :: proc(writer: ^Archive_Writer) -> errs.Error {
	if writer == nil {
		return {}
	}
	return journal.writer_close(&writer.writer)
}

archive_restore_entry :: proc(doc: ^Doc, entry: Log_Entry, allocator := context.allocator) -> errs.Error {
	if entry.id != Transaction_ID(doc.next_id) {
		return errs.newf(.Invalid_Input, "txn: archived transaction IDs are not dense", allocator = allocator)
	}
	if entry.parent >= entry.id {
		return errs.newf(.Invalid_Input, "txn: archived transaction has an invalid parent", allocator = allocator)
	}
	expected_base := u64(0)
	expected_selection := Selection{}
	doc.tree.root = doc.initial_root
	if entry.parent != 0 {
		parent := doc.log[entry.parent - 1]
		expected_base = parent.after
		expected_selection = parent.after_selection
		doc.tree.root = parent.after_root
	}
	if entry.base != expected_base || entry.after != doc.next_revision {
		return errs.newf(.Invalid_Input, "txn: archived transaction revision chain is invalid", allocator = allocator)
	}
	if entry.before_selection != expected_selection {
		return errs.newf(.Invalid_Input, "txn: archived before-selection does not match its parent", allocator = allocator)
	}
	if len(entry.ops) == 0 {
		return errs.newf(.Invalid_Input, "txn: archived transaction has no operations", allocator = allocator)
	}
	effective := false
	for op in entry.ops {
		switch o in op {
		case Insert:
			if len(o.data) > 0 {
				effective = true
			}
		case Delete, Replace:
			effective = true
		}
	}
	if !effective {
		return errs.newf(.Invalid_Input, "txn: archived transaction is a no-op", allocator = allocator)
	}
	doc.current = entry.parent
	doc.revision = expected_base
	transaction := Transaction {
		source = entry.source,
		base_revision = entry.base,
		grouping_key = entry.grouping_key,
		ops = entry.ops,
		after_selection = entry.after_selection,
	}
	if apply_err := doc_apply(doc, &transaction, allocator); !errs.ok(apply_err) {
		return apply_err
	}
	doc.log[len(doc.log) - 1].timestamp = entry.timestamp
	return {}
}

// archive_replay validates base_content against the archive header, then
// restores the complete verified transaction prefix through doc_apply. A torn,
// corrupt, or budget-stopped tail returns its journal status together with the
// successfully restored prefix. A checksummed but semantically invalid payload
// is an error and leaves doc uninitialized. On success, doc owns all restored
// state and the caller must eventually call doc_destroy. The active node is the
// newest valid node; persisting an earlier branch-selection position is M14.04.
archive_replay :: proc(
	path: string,
	base_content: []byte,
	doc_options: Options,
	limits: journal.Limits,
	doc: ^Doc,
	allocator := context.allocator,
) -> (status: journal.Replay_Status, err: errs.Error) {
	if doc == nil {
		return {}, errs.newf(.Invalid_Input, "txn: nil archive destination", allocator = allocator)
	}
	replay, replay_err := journal.replay(path, limits, allocator)
	if !errs.ok(replay_err) {
		return {}, replay_err
	}
	defer journal.replay_destroy(&replay)
	status = replay.status
	if replay.header.base_hash != journal.hash_base(base_content) {
		return status, errs.newf(.Conflict, "txn: undo archive base-content hash does not match", allocator = allocator)
	}
	if init_err := doc_init_from_bytes(doc, base_content, doc_options, allocator); !errs.ok(init_err) {
		return status, init_err
	}
	defer if !errs.ok(err) {
		doc_destroy(doc)
	}

	for record in replay.records {
		entry, decode_err := archive_decode_entry(record.payload, allocator)
		if !errs.ok(decode_err) {
			return status, decode_err
		}
		if time.to_unix_nanoseconds(entry.timestamp) != record.timestamp_unix_ns {
			ops_destroy(entry.ops, allocator)
			return status, errs.newf(.Invalid_Input, "txn: archive record timestamps disagree", allocator = allocator)
		}
		restore_err := archive_restore_entry(doc, entry, allocator)
		ops_destroy(entry.ops, allocator)
		if !errs.ok(restore_err) {
			return status, restore_err
		}
	}
	if check_err := doc_check(doc, allocator); !errs.ok(check_err) {
		return status, check_err
	}
	return status, {}
}
