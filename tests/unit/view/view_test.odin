package view_test

import "core:testing"

import errs "hammer:core/errs"
import layout "hammer:core/layout"
import tagstate "hammer:core/tag"
import txn "hammer:core/txn"
import view "hammer:core/view"

make_state :: proc(t: ^testing.T) -> view.State {
	state: view.State
	for id in 1 ..= 3 {
		err := view.add(&state, layout.Window_ID(id), 7)
		testing.expect(t, errs.ok(err))
		errs.destroy(&err)
	}
	return state
}

@(test)
test_views_own_independent_ui_state :: proc(t: ^testing.T) {
	state := make_state(t)
	first, first_ok := view.find(&state, 1)
	second, second_ok := view.find(&state, 2)
	testing.expect(t, first_ok && second_ok)
	first.selection = {anchor = 2, active = 5, affinity = .Right}
	first.first_line = 3
	first.wrap_mode = .Soft
	first.horizontal_offset = 12
	second.selection = {anchor = 8, active = 1, affinity = .Left}
	second.first_line = 9
	second.wrap_mode = .Truncate
	second.horizontal_offset = 48
	testing.expect(t, first.buffer_id == second.buffer_id)
	testing.expect(t, first.selection.anchor == 2 && second.selection.anchor == 8)
	testing.expect(t, first.first_line == 3 && second.first_line == 9)
	testing.expect(t, first.wrap_mode == .Soft && second.wrap_mode == .Truncate)
	testing.expect(t, first.horizontal_offset == 12 && second.horizontal_offset == 48)
	testing.expect(t, view.buffer_view_count(&state, 7) == 3)
	testing.expect(t, view.buffer_view_count(&state, 8) == 0)

	err := view.add(&state, 1, 7)
	testing.expect(t, err.kind == .Conflict)
	errs.destroy(&err)
}

@(test)
test_other_view_selections_follow_edit_operations :: proc(t: ^testing.T) {
	state := make_state(t)
	first, _ := view.find(&state, 1)
	second, _ := view.find(&state, 2)
	third, _ := view.find(&state, 3)
	first.selection = {anchor = 2, active = 2}
	second.selection = {anchor = 1, active = 4, affinity = .Right}
	third.selection = {anchor = 3, active = 10, affinity = .Left}
	ops := []txn.Operation{
		txn.Insert{pos = 2, data = []u8{'x', 'y'}},
		txn.Delete{range = {start = 8, end = 10}},
	}
	view.transform_after_edit(&state, 1, 7, ops, 10)
	testing.expect(t, first.selection.anchor == 2 && first.selection.active == 2)
	testing.expect(t, second.selection.anchor == 1 && second.selection.active == 6)
	testing.expect(t, third.selection.anchor == 5 && third.selection.active == 10)
}

@(test)
test_edit_clamps_stale_other_view_selection_to_document_end :: proc(t: ^testing.T) {
	state := make_state(t)
	second, _ := view.find(&state, 2)
	second.selection = {anchor = 11, active = 11, visual_column = 8}
	ops := []txn.Operation{txn.Delete{range = {start = 0, end = 7}}}
	view.transform_after_edit(&state, 1, 7, ops, 4)
	testing.expect(t, second.selection.anchor == 4 && second.selection.active == 4)
	testing.expect(t, second.selection.visual_column == 0)
}

@(test)
test_history_jump_clamps_only_other_views :: proc(t: ^testing.T) {
	state := make_state(t)
	first, _ := view.find(&state, 1)
	second, _ := view.find(&state, 2)
	first.selection = {anchor = 4, active = 6}
	second.selection = {anchor = 20, active = 30, visual_column = 12}
	second.first_line = -1
	view.clamp_after_history_jump(&state, 1, 7, 10)
	testing.expect(t, first.selection.anchor == 4 && first.selection.active == 6)
	testing.expect(t, second.selection.anchor == 10 && second.selection.active == 10)
	testing.expect(t, second.selection.visual_column == 0)
	testing.expect(t, second.first_line == 0)
}

@(test)
test_remove_view_preserves_buffer_and_other_views :: proc(t: ^testing.T) {
	state := make_state(t)
	second, _ := view.find(&state, 2)
	second.selection = {anchor = 3, active = 4}
	testing.expect(t, view.remove(&state, 2))
	testing.expect(t, !view.remove(&state, 2))
	testing.expect(t, state.view_count == 2)
	testing.expect(t, view.buffer_view_count(&state, 7) == 2)
	_, found := view.find(&state, 2)
	testing.expect(t, !found)
	first, first_ok := view.find(&state, 1)
	third, third_ok := view.find(&state, 3)
	testing.expect(t, first_ok && third_ok)
	testing.expect(t, first.buffer_id == 7 && third.buffer_id == 7)
}

@(test)
test_remove_does_not_relocate_owned_tag_documents :: proc(t: ^testing.T) {
	state := make_state(t)
	for index in 0 ..< view.MAX_VIEWS {
		item := &state.views[index]
		if item.window_id == 0 {
			continue
		}
		err := tagstate.init(&item.tag, "New | ", context.allocator)
		testing.expect(t, errs.ok(err))
		errs.destroy(&err)
	}
	first, _ := view.find(&state, 1)
	second, _ := view.find(&state, 2)
	third, _ := view.find(&state, 3)
	second_address := &second.tag.doc
	third_address := &third.tag.doc
	tagstate.destroy(&first.tag)
	testing.expect(t, view.remove(&state, 1))
	second_after, _ := view.find(&state, 2)
	third_after, _ := view.find(&state, 3)
	testing.expect(t, &second_after.tag.doc == second_address)
	testing.expect(t, &third_after.tag.doc == third_address)
	text, err := tagstate.text(&second_after.tag, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	testing.expect(t, text == "New | ")
	delete(text, context.allocator)
	tagstate.destroy(&second_after.tag)
	tagstate.destroy(&third_after.tag)
}


@(test)
test_edit_and_history_ignore_other_buffers :: proc(t: ^testing.T) {
	state := make_state(t)
	first, _ := view.find(&state, 1)
	second, _ := view.find(&state, 2)
	third, _ := view.find(&state, 3)
	second.selection = {anchor = 1, active = 4, affinity = .Right}
	third.buffer_id = 8
	third.selection = {anchor = 3, active = 10, affinity = .Left}
	third.first_line = -1
	ops := []txn.Operation{txn.Insert{pos = 2, data = []u8{'x', 'y'}}}
	view.transform_after_edit(&state, 1, 7, ops, 10)
	testing.expect(t, second.selection.active == 6)
	testing.expect(t, third.selection.anchor == 3 && third.selection.active == 10)

	view.clamp_after_history_jump(&state, 1, 7, 10)
	testing.expect(t, third.selection.anchor == 3 && third.selection.active == 10)
	testing.expect(t, third.first_line == -1)
	testing.expect(t, first.selection.anchor == 0 && first.selection.active == 0)
}
