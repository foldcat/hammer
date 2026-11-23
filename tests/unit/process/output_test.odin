package process_test

import "core:testing"

import process "hammer:core/process"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

@(test)
test_output_append_trims_scrollback_and_collapses_history :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init(&doc, {}, context.allocator))
	defer txn.doc_destroy(&doc)
	output: process.Output_Buffer
	expect_ok(t, process.output_init(&output, &doc, {batch_bytes = 5, scrollback_bytes = 10}, context.allocator))
	defer process.output_destroy(&output)
	previous_revision := u64(0)
	texts := []string{"abcd\n", "efgh\n", "ijkl\n"}
	for text, index in texts {
		expect_ok(t, process.output_append(&output, transmute([]byte)text))
		expected_end := min(10, (index + 1) * 5)
		testing.expect(t, output.has_update && output.update.end == expected_end)
		testing.expect(t, txn.doc_revision(&doc) > previous_revision)
		previous_revision = txn.doc_revision(&doc)
		testing.expect(t, txn.doc_log_len(&doc) == 0)
	}
	content, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	expect_ok(t, read_err)
	defer delete(content, context.allocator)
	testing.expect(t, string(content) == "efgh\nijkl\n")
	testing.expect(t, output.dropped_bytes == 5)
	too_long := process.output_append(&output, transmute([]byte)string("too long"))
	expect_kind(t, too_long, .Resource_Limit)
	testing.expect(t, txn.doc_revision(&doc) == previous_revision)
}

@(test)
test_output_clear_replaces_content_and_decoder_state :: proc(t: ^testing.T) {
	doc: txn.Doc
	expect_ok(t, txn.doc_init(&doc, {}, context.allocator))
	defer txn.doc_destroy(&doc)
	output: process.Output_Buffer
	expect_ok(t, process.output_init(&output, &doc, {}, context.allocator))
	defer process.output_destroy(&output)

	expect_ok(t, process.output_append(&output, transmute([]byte)string("first\n")))
	expect_ok(t, process.output_append(&output, transmute([]byte)string("discarded partial")))
	previous_revision := txn.doc_revision(&doc)
	expect_ok(t, process.output_clear(&output))
	testing.expect(t, output.has_update && output.update.end == 0)
	testing.expect(t, rope.tree_byte_count(&doc.tree) == 0)
	testing.expect(t, txn.doc_revision(&doc) > previous_revision)
	testing.expect(t, txn.doc_log_len(&doc) == 0)
	testing.expect(t, output.dropped_bytes == 0)

	expect_ok(t, process.output_append(&output, transmute([]byte)string("second\n")))
	expect_ok(t, process.output_finish(&output))
	content, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	expect_ok(t, read_err)
	defer delete(content, context.allocator)
	testing.expect(t, string(content) == "second\n")

	empty_revision := txn.doc_revision(&doc)
	expect_ok(t, process.output_clear(&output))
	testing.expect(t, output.has_update)
	testing.expect(t, txn.doc_revision(&doc) > empty_revision)
	testing.expect(t, rope.tree_byte_count(&doc.tree) == 0)

	empty_revision = txn.doc_revision(&doc)
	expect_ok(t, process.output_clear(&output))
	testing.expect(t, !output.has_update)
	testing.expect(t, txn.doc_revision(&doc) == empty_revision)
}

@(test)
test_output_flood_is_ordered_and_bounded :: proc(t: ^testing.T) {
	handle, spawn_err := process.spawn({command = {HELPER, "flood"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	pump: process.Pump
	expect_ok(t, process.pump_init(&pump, &handle, nil, {record_capacity = 2, chunk_bytes = 64}, context.allocator))
	defer expect_ok(t, process.pump_destroy(&pump))
	doc: txn.Doc
	expect_ok(t, txn.doc_init(&doc, {}, context.allocator))
	defer txn.doc_destroy(&doc)
	output: process.Output_Buffer
	expect_ok(t, process.output_init(&output, &doc, {batch_bytes = 128, scrollback_bytes = 256}, context.allocator))
	defer process.output_destroy(&output)
	reference := make([dynamic]byte, 0, 512 * 1024, context.allocator)
	defer delete(reference)
	updates := 0
	for iteration in 0 ..< 200000 {
		expect_ok(t, process.pump_poll(&pump))
		consumed, consume_err := process.output_consume(&output, &pump, 128)
		expect_ok(t, consume_err)
		testing.expect(t, consumed >= 0 && consumed <= 128)
		if output.has_update {
			updates += 1
			testing.expect(t, output.update.end <= 256)
			testing.expect(t, output.update.trimmed >= 0)
			testing.expect(t, txn.doc_log_len(&doc) == 0)
			operation := output.update.transaction.ops[len(output.update.transaction.ops) - 1]
			insert, ok := operation.(txn.Insert)
			// A line held across a batch boundary is emitted whole in the next
			// batch, so a single insert may be up to one batch plus one carried
			// partial line. Flood lines are short, so twice the batch bounds it.
			testing.expect(t, ok && len(insert.data) <= 256)
			if ok {
				append(&reference, ..insert.data)
			}
		}
		if process.pump_drained(&pump) {
			break
		}
		testing.expect(t, iteration < 199999, "output flood did not drain within the polling budget")
	}
	testing.expect(t, updates > 0 && len(reference) > 256)
	content, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	expect_ok(t, read_err)
	defer delete(content, context.allocator)
	testing.expect(t, len(content) == 256)
	testing.expect(t, string(content) == string(reference[len(reference) - 256:]))
	testing.expect(t, output.dropped_bytes == u64(len(reference) - len(content)))
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success)
}

@(test)
test_output_decodes_ansi_progress_and_tail :: proc(t: ^testing.T) {
	handle, spawn_err := process.spawn({command = {HELPER, "ansi"}}, context.allocator)
	if !expect_ok(t, spawn_err) {
		return
	}
	defer cleanup(t, &handle)
	pump: process.Pump
	expect_ok(t, process.pump_init(&pump, &handle, nil, {record_capacity = 8, chunk_bytes = 4}, context.allocator))
	defer expect_ok(t, process.pump_destroy(&pump))
	doc: txn.Doc
	expect_ok(t, txn.doc_init(&doc, {}, context.allocator))
	defer txn.doc_destroy(&doc)
	output: process.Output_Buffer
	expect_ok(t, process.output_init(&output, &doc, {batch_bytes = 64, scrollback_bytes = 1024}, context.allocator))
	defer process.output_destroy(&output)
	for iteration in 0 ..< 100000 {
		expect_ok(t, process.pump_poll(&pump))
		_, consume_err := process.output_consume(&output, &pump, 64)
		expect_ok(t, consume_err)
		if process.pump_drained(&pump) {
			break
		}
		testing.expect(t, iteration < 99999, "ansi output did not drain within the polling budget")
	}
	expect_ok(t, process.output_finish(&output))
	content, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	expect_ok(t, read_err)
	defer delete(content, context.allocator)
	testing.expectf(
		t,
		string(content) == "red\ngreen\nvwxyz\nno-newline-tail\n",
		"got %q",
		string(content),
	)
	status, wait_err := process.wait(&handle, context.allocator)
	expect_ok(t, wait_err)
	testing.expect(t, status.success)
}
