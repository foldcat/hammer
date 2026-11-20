package tag_test

import "core:testing"

import errs "hammer:core/errs"
import rope "hammer:core/rope"
import tagstate "hammer:core/tag"
import txn "hammer:core/txn"

expect_text :: proc(t: ^testing.T, state: ^tagstate.State, want: string) {
	got, err := tagstate.text(state, context.allocator)
	defer delete(got, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expectf(t, got == want, "tag text %q != %q", got, want)
}

append_suffix :: proc(t: ^testing.T, state: ^tagstate.State, suffix: string) {
	end := rope.tree_byte_count(&state.doc.tree)
	ops := []txn.Operation{txn.Insert{pos = end, data = transmute([]byte)suffix}}
	selection := txn.Selection{anchor = end + len(suffix), active = end + len(suffix)}
	transaction := txn.Transaction {
		source = .Typing,
		base_revision = txn.doc_revision(&state.doc),
		ops = ops,
		after_selection = selection,
	}
	err := txn.doc_apply(&state.doc, &transaction, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	state.selection = selection
}

@(test)
test_refresh_preserves_user_suffix_and_selection :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "New Del | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)
	append_suffix(t, &state, "echo")
	state.selection = {anchor = state.generated_end, active = rope.tree_byte_count(&state.doc.tree), affinity = .Right}
	previous_revision := txn.doc_revision(&state.doc)

	err = tagstate.refresh_generated(&state, "New Del Put | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_text(t, &state, "New Del Put | echo")
	testing.expect(t, state.generated_end == len("New Del Put | "))
	testing.expect(t, state.selection.anchor == len("New Del Put | "))
	testing.expect(t, state.selection.active == len("New Del Put | echo"))
	testing.expect(t, state.selection.affinity == .Right)

	err = tagstate.refresh_generated(&state, "New Del Put | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, txn.doc_revision(&state.doc) == previous_revision + 1)
	expect_text(t, &state, "New Del Put | echo")
}

@(test)
test_refresh_can_remove_generated_command_without_touching_suffix :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "file.txt Del Put | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)
	append_suffix(t, &state, "Look")
	err = tagstate.refresh_generated(&state, "file.txt Del | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_text(t, &state, "file.txt Del | Look")
	testing.expect(t, state.selection.active == len("file.txt Del | Look"))
}

@(test)
test_generated_input_validation :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "", context.allocator)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	err = tagstate.init(&state, "New | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)
	ops := []txn.Operation{txn.Delete{range = {0, rope.tree_byte_count(&state.doc.tree)}}}
	transaction := txn.Transaction {
		source = .Edit,
		base_revision = txn.doc_revision(&state.doc),
		ops = ops,
		after_selection = {},
	}
	err = txn.doc_apply(&state.doc, &transaction, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	state.selection = {}
	state.generated_end = 100
	err = tagstate.refresh_generated(&state, "Other | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_text(t, &state, "Other | ")
}

@(test)
test_filepath_boundary_and_immutable_region :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "file.txt Del Put | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)

	testing.expect(t, state.filepath_end == len("file.txt"))
	testing.expect(t, state.generated_end == len("file.txt Del Put | "))
	testing.expect(t, state.lock_commands)

	// Typing is allowed at the filepath (and its separating space) and the
	// suffix, blocked inside the generated-commands region.
	testing.expect(t, tagstate.edit_allowed(&state, 0))
	testing.expect(t, tagstate.edit_allowed(&state, len("file.txt")))
	testing.expect(t, !tagstate.edit_allowed(&state, len("file.txt") + 1))
	testing.expect(t, tagstate.edit_allowed(&state, state.generated_end))

	// Deletion is blocked inside the commands region, allowed at the filepath
	// and the suffix. A collapsed caret is treated by its byte offset.
	testing.expect(t, tagstate.deletion_allowed(&state, {anchor = 0, active = 0}))
	testing.expect(t, tagstate.deletion_allowed(&state, {anchor = len("file.txt"), active = len("file.txt")}))
	testing.expect(t, !tagstate.deletion_allowed(&state, {anchor = len("file.txt") + 1, active = len("file.txt") + 1}))
	testing.expect(t, tagstate.deletion_allowed(&state, {anchor = state.generated_end, active = state.generated_end}))
	// A selection spanning the commands region is also blocked.
	testing.expect(t, !tagstate.deletion_allowed(&state, {anchor = len("file.txt"), active = state.generated_end}))

	fp, fp_err := tagstate.filepath(&state, context.allocator)
	defer delete(fp, context.allocator)
	testing.expect(t, errs.ok(fp_err))
	errs.destroy(&fp_err)
	testing.expect(t, fp == "file.txt")
}

@(test)
test_unlocked_tag_is_fully_editable :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "New Del | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)

	// A blank buffer clears the lock so the whole tag can be edited.
	state.lock_commands = false
	for offset in 0 ..= state.generated_end + 2 {
		testing.expectf(
			t,
			tagstate.edit_allowed(&state, offset),
			"edit_allowed should hold at offset %v when unlocked",
			offset,
		)
		testing.expectf(
			t,
			tagstate.deletion_allowed(&state, {anchor = offset, active = offset}),
			"deletion_allowed should hold at offset %v when unlocked",
			offset,
		)
	}
}

@(test)
test_refresh_commands_preserves_name_and_caret :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "fresh.txt Del | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)

	// A caret in the middle of the name must survive a commands-only refresh.
	state.selection = {anchor = 4, active = 4, affinity = .Left}
	err = tagstate.refresh_commands(&state, "Del Put", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_text(t, &state, "fresh.txt Del Put | ")
	testing.expect(t, state.selection.anchor == 4 && state.selection.active == 4)
	testing.expect(t, state.filepath_end == len("fresh.txt"))
	testing.expect(t, state.generated_end == len("fresh.txt Del Put | "))

	// Refreshing with the same commands is a no-op.
	before := txn.doc_revision(&state.doc)
	err = tagstate.refresh_commands(&state, "Del Put", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, txn.doc_revision(&state.doc) == before)
	expect_text(t, &state, "fresh.txt Del Put | ")
}

@(test)
test_refresh_commands_boundary_caret_stays_put :: proc(t: ^testing.T) {
	state: tagstate.State
	err := tagstate.init(&state, "f Del | ", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer tagstate.destroy(&state)

	// After typing "f" over "New", the caret sits at filepath_end (the space
	// that separates the name from the commands). A commands refresh inserts
	// Put but must not push the caret past the new commands.
	state.selection = {anchor = 1, active = 1, affinity = .Left}
	err = tagstate.refresh_commands(&state, "Del Put", context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	expect_text(t, &state, "f Del Put | ")
	testing.expect(t, state.selection.anchor == 1 && state.selection.active == 1)
}
