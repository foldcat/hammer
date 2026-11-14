// Persistent undo archive tests (M04.05): exact transaction/branch round
// trips, verified-prefix replay, semantic validation, identity, and limits.
package txn_test

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import errs "hammer:core/errs"
import journal "hammer:core/journal"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

archive_expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
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

archive_expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got error %v, expected %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

archive_sandbox :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "hammer-undo-archive-*", context.allocator)
	if err != nil {
		testing.expectf(t, false, "creating archive sandbox failed: %v", err)
		return ""
	}
	return dir
}

archive_sandbox_destroy :: proc(dir: string) {
	if dir != "" {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
}

archive_test_path :: proc(dir, name: string) -> string {
	return fmt.tprintf("%s/%s.archive", dir, name)
}

archive_test_header :: proc(base: []byte) -> journal.Header {
	return journal.Header {
		path = "/project/example.txt",
		base_hash = journal.hash_base(base),
		session_id = 0x1234,
		process_instance_id = 0x5678,
		generation = 1,
		created_unix_ns = 123456,
	}
}

archive_write_doc :: proc(t: ^testing.T, path: string, doc: ^txn.Doc, base: []byte, options := journal.Options{flush = .None}) -> bool {
	writer, create_err := txn.archive_create(path, archive_test_header(base), options, context.allocator)
	if !archive_expect_ok(t, create_err) {
		return false
	}
	succeeded := true
	for entry in doc.log {
		if !archive_expect_ok(t, txn.archive_append(&writer, entry)) {
			succeeded = false
			break
		}
	}
	if !archive_expect_ok(t, txn.archive_close(&writer)) {
		succeeded = false
	}
	return succeeded
}

archive_write_raw :: proc(
	t: ^testing.T,
	path: string,
	base: []byte,
	entry: txn.Log_Entry,
	timestamp_delta := i64(0),
) -> bool {
	payload, encode_err := txn.archive_encode_entry(entry, context.allocator)
	if !archive_expect_ok(t, encode_err) {
		return false
	}
	defer delete(payload, context.allocator)
	writer, create_err := journal.create(path, archive_test_header(base), {flush = .None}, context.allocator)
	if !archive_expect_ok(t, create_err) {
		return false
	}
	succeeded := archive_expect_ok(
		t,
		journal.writer_append(
			&writer,
			u64(entry.id),
			time.to_unix_nanoseconds(entry.timestamp) + timestamp_delta,
			payload,
		),
	)
	if !archive_expect_ok(t, journal.writer_close(&writer)) {
		succeeded = false
	}
	return succeeded
}

archive_root_bytes :: proc(t: ^testing.T, doc: ^txn.Doc, root: ^rope.Node) -> []byte {
	total := 0 if root == nil else root.metrics.byte_count
	content, err := rope.tree_read_root_all(&doc.tree, root, {0, total}, context.allocator)
	archive_expect_ok(t, err)
	return content
}

archive_expect_same_node :: proc(t: ^testing.T, original, restored: ^txn.Doc, index: int) {
	want := original.log[index]
	got := restored.log[index]
	testing.expect(t, got.parent == want.parent)
	testing.expect(t, len(got.children) == len(want.children))
	for child, child_index in want.children {
		testing.expect(t, got.children[child_index] == child)
	}
	want_payload, want_err := txn.archive_encode_entry(want, context.allocator)
	if !archive_expect_ok(t, want_err) {
		return
	}
	defer delete(want_payload, context.allocator)
	got_payload, got_err := txn.archive_encode_entry(got, context.allocator)
	if !archive_expect_ok(t, got_err) {
		return
	}
	defer delete(got_payload, context.allocator)
	testing.expectf(t, bytes.equal(got_payload, want_payload), "encoded node %d differs after replay", index + 1)

	want_content := archive_root_bytes(t, original, want.after_root)
	defer delete(want_content, context.allocator)
	got_content := archive_root_bytes(t, restored, got.after_root)
	defer delete(got_content, context.allocator)
	testing.expectf(t, bytes.equal(got_content, want_content), "snapshot node %d differs after replay", index + 1)
}

archive_apply :: proc(
	t: ^testing.T,
	doc: ^txn.Doc,
	source: txn.Source,
	key: u64,
	ops: []txn.Operation,
	selection: txn.Selection,
) {
	transaction := txn.Transaction {
		source = source,
		base_revision = txn.doc_revision(doc),
		grouping_key = key,
		ops = ops,
		after_selection = selection,
	}
	archive_expect_ok(t, txn.doc_apply(doc, &transaction))
}

@(test)
test_archive_branch_round_trip :: proc(t: ^testing.T) {
	dir := archive_sandbox(t)
	defer archive_sandbox_destroy(dir)
	base := bytes_of("base\n")
	original: txn.Doc
	if !archive_expect_ok(t, txn.doc_init_from_bytes(&original, base, {chunk_size = 4, target_leaf_bytes = 16})) {
		return
	}
	defer txn.doc_destroy(&original)

	archive_apply(t, &original, .Typing, 10, {insert_op(5, "one")}, sel(5, 8, .Right, 2))
	archive_apply(t, &original, .Edit, 20, {replace_op(0, 4, "BASE"), insert_op(5, "!")}, sel(0, 4, .Left, 0))
	_, undo_err := txn.doc_undo(&original)
	archive_expect_ok(t, undo_err)
	archive_apply(t, &original, .Paste, 77, {insert_op(8, " two")}, sel(8, 12, .Right, 4))
	archive_apply(t, &original, .Cut, 77, {delete_op(8, 12)}, sel(8, 8, .Left, 0))
	original.log[0].timestamp = time.from_nanoseconds(-123456789)
	original.log[3].timestamp = time.from_nanoseconds(987654321)

	// Saving while undone must retain every node. M04.05 restores the newest
	// node; persisting this earlier active position is M14.04.
	_, second_undo_err := txn.doc_undo(&original)
	archive_expect_ok(t, second_undo_err)
	testing.expect(t, original.current == 1)
	path := archive_test_path(dir, "branches")
	if !archive_write_doc(t, path, &original, base) {
		return
	}

	restored: txn.Doc
	status, replay_err := txn.archive_replay(path, base, {chunk_size = 4, target_leaf_bytes = 16}, {}, &restored, context.allocator)
	if !archive_expect_ok(t, replay_err) {
		return
	}
	defer txn.doc_destroy(&restored)
	testing.expect(t, status == .Complete)
	testing.expect(t, txn.doc_log_len(&restored) == 4)
	testing.expect(t, restored.current == 4)
	testing.expect(t, restored.next_id == original.next_id)
	testing.expect(t, restored.next_revision == original.next_revision)
	expect_doc_ok(t, &restored, "archive round trip")
	for index in 0 ..< len(original.log) {
		archive_expect_same_node(t, &original, &restored, index)
	}
	testing.expect(t, len(restored.log[0].children) == 2)
	testing.expect(t, restored.log[0].children[0] == 2 && restored.log[0].children[1] == 3)

	// The t3+t4 grouping run survives, as does the abandoned t2 snapshot.
	_, restored_undo_err := txn.doc_undo(&restored)
	archive_expect_ok(t, restored_undo_err)
	testing.expect(t, restored.current == 1)
	content := doc_flatten(t, &restored)
	testing.expect(t, bytes.equal(content, bytes_of("base\none")))
	delete(content)
	_, restored_redo_err := txn.doc_redo(&restored)
	archive_expect_ok(t, restored_redo_err)
	testing.expect(t, restored.current == 4)

	// Revision zero is the supplied nonempty base, not a synthetic log node.
	_, undo_group_err := txn.doc_undo(&restored)
	archive_expect_ok(t, undo_group_err)
	_, undo_base_err := txn.doc_undo(&restored)
	archive_expect_ok(t, undo_base_err)
	testing.expect(t, restored.current == 0)
	base_content := doc_flatten(t, &restored)
	testing.expect(t, bytes.equal(base_content, base))
	delete(base_content)
	expect_doc_ok(t, &restored, "nonempty archive base")
}

@(test)
test_archive_verified_prefix :: proc(t: ^testing.T) {
	dir := archive_sandbox(t)
	defer archive_sandbox_destroy(dir)
	base := bytes_of("x")
	original: txn.Doc
	archive_expect_ok(t, txn.doc_init_from_bytes(&original, base, {chunk_size = 4}))
	defer txn.doc_destroy(&original)
	archive_apply(t, &original, .Typing, 0, {insert_op(1, "a")}, sel(2, 2, .Right, 0))
	archive_apply(t, &original, .Typing, 0, {insert_op(2, "b")}, sel(3, 3, .Right, 0))
	archive_apply(t, &original, .Typing, 0, {insert_op(3, "c")}, sel(4, 4, .Right, 0))
	path := archive_test_path(dir, "prefix")
	if !archive_write_doc(t, path, &original, base) {
		return
	}
	complete, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(complete, context.allocator)

	testing.expect(t, os.write_entire_file(path, complete[:len(complete) - 7]) == nil)
	torn: txn.Doc
	torn_status, torn_err := txn.archive_replay(path, base, {}, {}, &torn, context.allocator)
	if archive_expect_ok(t, torn_err) {
		defer txn.doc_destroy(&torn)
		testing.expect(t, torn_status == .Torn_Record)
		testing.expect(t, txn.doc_log_len(&torn) == 2)
		torn_content := doc_flatten(t, &torn)
		testing.expect(t, bytes.equal(torn_content, bytes_of("xab")))
		delete(torn_content)
		expect_doc_ok(t, &torn, "torn archive prefix")
	}

	corrupt := bytes.clone(complete, context.allocator)
	defer delete(corrupt, context.allocator)
	corrupt[len(corrupt) - 5] ~= 0xff
	testing.expect(t, os.write_entire_file(path, corrupt) == nil)
	bad: txn.Doc
	bad_status, bad_err := txn.archive_replay(path, base, {}, {}, &bad, context.allocator)
	if archive_expect_ok(t, bad_err) {
		defer txn.doc_destroy(&bad)
		testing.expect(t, bad_status == .Checksum_Mismatch)
		testing.expect(t, txn.doc_log_len(&bad) == 2)
		expect_doc_ok(t, &bad, "corrupt archive prefix")
	}
}

@(test)
test_archive_decode_validation :: proc(t: ^testing.T) {
	entry := txn.Log_Entry {
		id = 1,
		source = .Edit,
		base = 0,
		after = 1,
		grouping_key = 99,
		timestamp = time.from_nanoseconds(-42),
		before_selection = sel(0, 0, .Left, 0),
		after_selection = sel(1, 1, .Right, 1.5),
		ops = {insert_op(0, "x")},
	}
	payload, encode_err := txn.archive_encode_entry(entry, context.allocator)
	if !archive_expect_ok(t, encode_err) {
		return
	}
	defer delete(payload, context.allocator)
	decoded, decode_err := txn.archive_decode_entry(payload, context.allocator)
	if archive_expect_ok(t, decode_err) {
		reencoded, reencode_err := txn.archive_encode_entry(decoded, context.allocator)
		archive_expect_ok(t, reencode_err)
		testing.expect(t, bytes.equal(reencoded, payload))
		delete(reencoded, context.allocator)
		txn.ops_destroy(decoded.ops, context.allocator)
	}

	Mutation :: struct {
		offset: int,
		value: u32,
		kind: errs.Kind,
	}
	mutations := []Mutation {
		{0, 99, .Unsupported},
		{4, 0xffff_ffff, .Invalid_Input},
		{72, 9, .Invalid_Input},
		{76, 1, .Invalid_Input},
		{104, 9, .Invalid_Input},
		{108, 1, .Invalid_Input},
		{120, 255, .Invalid_Input},
		{124, 1, .Invalid_Input},
		{128, 99, .Invalid_Input},
		{132, 1, .Invalid_Input},
		{152, 0xffff_ffff, .Invalid_Input},
		{156, 1, .Invalid_Input},
	}
	for mutation in mutations {
		bad := bytes.clone(payload, context.allocator)
		endian.put_u32(bad[mutation.offset:], .Little, mutation.value)
		result, err := txn.archive_decode_entry(bad, context.allocator)
		archive_expect_kind(t, err, mutation.kind)
		txn.ops_destroy(result.ops, context.allocator)
		delete(bad, context.allocator)
	}
	mismatched := bytes.clone(payload, context.allocator)
	endian.put_i64(mismatched[144:], .Little, 1)
	result, mismatch_err := txn.archive_decode_entry(mismatched, context.allocator)
	archive_expect_kind(t, mismatch_err, .Invalid_Input)
	txn.ops_destroy(result.ops, context.allocator)
	delete(mismatched, context.allocator)
	short_result, short_err := txn.archive_decode_entry(payload[:20], context.allocator)
	archive_expect_kind(t, short_err, .Invalid_Input)
	txn.ops_destroy(short_result.ops, context.allocator)
	trailing := make([dynamic]byte, context.allocator)
	append(&trailing, ..payload)
	append(&trailing, 0)
	trailing_result, trailing_err := txn.archive_decode_entry(trailing[:], context.allocator)
	archive_expect_kind(t, trailing_err, .Invalid_Input)
	txn.ops_destroy(trailing_result.ops, context.allocator)
	delete(trailing)
}

@(test)
test_archive_semantic_rejection :: proc(t: ^testing.T) {
	dir := archive_sandbox(t)
	defer archive_sandbox_destroy(dir)
	base := bytes_of("base")
	entry := txn.Log_Entry {
		id = 1,
		source = .Typing,
		after = 1,
		timestamp = time.from_nanoseconds(123),
		ops = {txn.Operation(txn.Insert{pos = 0, data = {}})},
	}
	noop_path := archive_test_path(dir, "noop")
	if archive_write_raw(t, noop_path, base, entry) {
		restored: txn.Doc
		_, err := txn.archive_replay(noop_path, base, {}, {}, &restored, context.allocator)
		archive_expect_kind(t, err, .Invalid_Input)
	}

	entry.parent = 1
	entry.ops = {insert_op(0, "x")}
	entry.after_selection = sel(1, 1, .Right, 0)
	parent_path := archive_test_path(dir, "parent")
	if archive_write_raw(t, parent_path, base, entry) {
		restored: txn.Doc
		_, err := txn.archive_replay(parent_path, base, {}, {}, &restored, context.allocator)
		archive_expect_kind(t, err, .Invalid_Input)
	}

	entry.parent = 0
	timestamp_path := archive_test_path(dir, "timestamp")
	if archive_write_raw(t, timestamp_path, base, entry, 1) {
		restored: txn.Doc
		_, err := txn.archive_replay(timestamp_path, base, {}, {}, &restored, context.allocator)
		archive_expect_kind(t, err, .Invalid_Input)
	}
}

@(test)
test_archive_base_identity_and_limits :: proc(t: ^testing.T) {
	dir := archive_sandbox(t)
	defer archive_sandbox_destroy(dir)
	base := bytes_of("base")
	original: txn.Doc
	archive_expect_ok(t, txn.doc_init_from_bytes(&original, base, {}))
	defer txn.doc_destroy(&original)
	archive_apply(t, &original, .Typing, 0, {insert_op(4, " one")}, sel(8, 8, .Right, 0))
	archive_apply(t, &original, .Typing, 0, {insert_op(8, " two")}, sel(12, 12, .Right, 0))
	path := archive_test_path(dir, "limits")
	if !archive_write_doc(t, path, &original, base) {
		return
	}

	wrong: txn.Doc
	_, wrong_err := txn.archive_replay(path, bytes_of("BASE"), {}, {}, &wrong, context.allocator)
	archive_expect_kind(t, wrong_err, .Conflict)

	limited: txn.Doc
	limited_status, limited_err := txn.archive_replay(path, base, {}, {max_records = 1}, &limited, context.allocator)
	if archive_expect_ok(t, limited_err) {
		defer txn.doc_destroy(&limited)
		testing.expect(t, limited_status == .Record_Limit)
		testing.expect(t, txn.doc_log_len(&limited) == 1)
		expect_doc_ok(t, &limited, "record-limited archive")
	}
	payload_limited: txn.Doc
	payload_status, payload_err := txn.archive_replay(path, base, {}, {max_payload_bytes = txn.ARCHIVE_ENTRY_FIXED_SIZE}, &payload_limited, context.allocator)
	if archive_expect_ok(t, payload_err) {
		defer txn.doc_destroy(&payload_limited)
		testing.expect(t, payload_status == .Payload_Limit)
		testing.expect(t, txn.doc_log_len(&payload_limited) == 0)
		content := doc_flatten(t, &payload_limited)
		testing.expect(t, bytes.equal(content, base))
		delete(content)
	}

	small_path := archive_test_path(dir, "small-writer")
	writer, create_err := txn.archive_create(
		small_path,
		archive_test_header(base),
		{flush = .None, limits = {max_payload_bytes = txn.ARCHIVE_ENTRY_FIXED_SIZE + txn.ARCHIVE_OPERATION_SIZE}},
		context.allocator,
	)
	if archive_expect_ok(t, create_err) {
		archive_expect_kind(t, txn.archive_append(&writer, original.log[0]), .Resource_Limit)
		noop := txn.Log_Entry{id = 1, after = 1, ops = {txn.Operation(txn.Insert{pos = 0, data = {}})}}
		archive_expect_kind(t, txn.archive_append(&writer, noop), .Invalid_Input)
		archive_expect_kind(t, txn.archive_append(&writer, original.log[1]), .Conflict)
		archive_expect_ok(t, txn.archive_close(&writer))
		empty: txn.Doc
		empty_status, empty_err := txn.archive_replay(small_path, base, {}, {}, &empty, context.allocator)
		if archive_expect_ok(t, empty_err) {
			defer txn.doc_destroy(&empty)
			testing.expect(t, empty_status == .Complete)
			testing.expect(t, txn.doc_log_len(&empty) == 0)
			expect_doc_ok(t, &empty, "empty limited archive")
		}
	}
}

@(test)
test_archive_randomized_round_trip :: proc(t: ^testing.T) {
	dir := archive_sandbox(t)
	defer archive_sandbox_destroy(dir)
	original: txn.Doc
	archive_expect_ok(t, txn.doc_init(&original, {chunk_size = 3, target_leaf_bytes = 12}))
	defer txn.doc_destroy(&original)
	state := u64(0xd1b5_4a32_d192_ed03)
	next := proc(random_state: ^u64) -> u64 {
		value := random_state^
		value ~= value << 13
		value ~= value >> 7
		value ~= value << 17
		random_state^ = value
		return value
	}
	for _ in 0 ..< 120 {
		roll := next(&state) % 100
		if roll < 65 || (!txn.doc_undoable(&original) && !txn.doc_redoable(&original)) {
			length := rope.tree_byte_count(&original.tree)
			operation: txn.Operation
			after_length := length
			if length == 0 || next(&state) % 2 == 0 {
				position := int(next(&state) % u64(length + 1))
				data := []byte{byte('a' + next(&state) % 26)}
				operation = insert_op(position, string(data))
				after_length += 1
			} else {
				start := int(next(&state) % u64(length))
				end_position := start + 1 + int(next(&state) % u64(length - start))
				operation = delete_op(start, end_position)
				after_length -= end_position - start
			}
			selection := sel(0, 0, .Left, 0)
			if after_length > 0 {
				selection = sel(
					int(next(&state) % u64(after_length + 1)),
					int(next(&state) % u64(after_length + 1)),
					txn.Affinity(next(&state) % 2),
					f64(next(&state) % 5),
				)
			}
			archive_apply(t, &original, .Edit, next(&state) % 4, {operation}, selection)
		} else if roll < 85 {
			if txn.doc_undoable(&original) {
				_, err := txn.doc_undo(&original)
				archive_expect_ok(t, err)
			} else {
				_, err := txn.doc_redo(&original)
				archive_expect_ok(t, err)
			}
		} else {
			if txn.doc_redoable(&original) {
				_, err := txn.doc_redo(&original)
				archive_expect_ok(t, err)
			} else {
				_, err := txn.doc_undo(&original)
				archive_expect_ok(t, err)
			}
		}
	}
	path := archive_test_path(dir, "random")
	if !archive_write_doc(t, path, &original, {}) {
		return
	}
	restored: txn.Doc
	status, replay_err := txn.archive_replay(path, {}, {chunk_size = 3, target_leaf_bytes = 12}, {}, &restored, context.allocator)
	if !archive_expect_ok(t, replay_err) {
		return
	}
	defer txn.doc_destroy(&restored)
	testing.expect(t, status == .Complete)
	testing.expect(t, len(restored.log) == len(original.log))
	testing.expect(t, restored.current == txn.Transaction_ID(len(original.log)))
	for index in 0 ..< len(original.log) {
		archive_expect_same_node(t, &original, &restored, index)
	}
	expect_doc_ok(t, &restored, "random archive round trip")
}
