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
