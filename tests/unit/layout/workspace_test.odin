package layout_test

import "core:math"
import "core:testing"

import coords "hammer:core/coords"
import errs "hammer:core/errs"
import layout "hammer:core/layout"

Test_Workspace :: struct {
	value: layout.Workspace,
	left: layout.Column_ID,
	right: layout.Column_ID,
	first: layout.Window_ID,
	second: layout.Window_ID,
	third: layout.Window_ID,
}

make_workspace :: proc(t: ^testing.T) -> Test_Workspace {
	result: Test_Workspace
	err := layout.workspace_init(&result.value)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	result.left = result.value.columns[0].id
	result.first = result.value.columns[0].windows[0].id
	result.right, err = layout.add_column(&result.value)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	result.second, err = layout.add_window(&result.value, result.left)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	result.third, err = layout.add_window(&result.value, result.right)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	return result
}

arrange_test_workspace :: proc(t: ^testing.T, workspace: ^layout.Workspace) -> layout.Geometry {
	geometry, err := layout.arrange(workspace, {800, 600}, layout.default_metrics(20))
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	return geometry
}

@(test)
test_workspace_ids_and_capacity :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	testing.expect(t, workspace.left != workspace.right)
	testing.expect(t, workspace.first != workspace.second && workspace.second != workspace.third)
	column, window, ok := layout.find_window(&workspace.value, workspace.third)
	testing.expect(t, ok && column == 1 && window == 0)

	for _ in 2 ..< layout.MAX_COLUMNS {
		_, err := layout.add_column(&workspace.value)
		testing.expect(t, errs.ok(err))
		errs.destroy(&err)
	}
	_, err := layout.add_column(&workspace.value)
	testing.expect(t, err.kind == .Resource_Limit)
	errs.destroy(&err)

	for _ in 2 ..< layout.MAX_WINDOWS_PER_COLUMN {
		_, add_err := layout.add_window(&workspace.value, workspace.left)
		testing.expect(t, errs.ok(add_err))
		errs.destroy(&add_err)
	}
	_, add_err := layout.add_window(&workspace.value, workspace.left)
	testing.expect(t, add_err.kind == .Resource_Limit)
	errs.destroy(&add_err)
}

@(test)
test_workspace_geometry_partitions_and_hits :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	testing.expect(t, geometry.column_count == 2)
	expect_rect(t, geometry.global_tag, {0, 0, 800, 20}, "global tag")
	expect_rect(t, geometry.columns[0].frame, {0, 20, 399, 580}, "left column")
	expect_rect(t, geometry.columns[1].frame, {401, 20, 399, 580}, "right column")
	testing.expect(t, geometry.columns[0].window_count == 2)
	testing.expect(t, geometry.columns[1].window_count == 1)
	first := geometry.columns[0].windows[0]
	second := geometry.columns[0].windows[1]
	third := geometry.columns[1].windows[0]
	testing.expect(t, first.id == workspace.first && second.id == workspace.second && third.id == workspace.third)
	expect_rect(t, first.window.frame, {0, 44, 399, 277}, "first window")
	expect_rect(t, second.window.frame, {0, 323, 399, 277}, "second window")
	expect_rect(t, third.window.frame, {401, 44, 399, 556}, "third window")
	testing.expect(t, first.window.tag.y + first.window.tag.height == first.window.body.y)
	testing.expect(t, second.window.frame.y == first.window.frame.y + first.window.frame.height + 2)

	hit := layout.hit_test(&geometry, {3, 25})
	testing.expect(t, hit.kind == .Column_Control && hit.column_id == workspace.left)
	hit = layout.hit_test(&geometry, {3, 50})
	testing.expect(t, hit.kind == .Window_Control && hit.window_id == workspace.first)
	hit = layout.hit_test(&geometry, {100, 100})
	testing.expect(t, hit.kind == .Body && hit.window_id == workspace.first)
	hit = layout.hit_test(&geometry, {100, 10})
	testing.expect(t, hit.kind == .Global_Tag)
}

@(test)
test_workspace_degenerate_geometry :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry, err := layout.arrange(&workspace.value, {0, 0}, layout.default_metrics(20))
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	for column_index in 0 ..< geometry.column_count {
		column := &geometry.columns[column_index]
		testing.expect(t, column.frame.width >= 0 && column.frame.height >= 0)
		for placed in column.windows[:column.window_count] {
			testing.expect(t, placed.window.frame.width >= 0 && placed.window.frame.height >= 0)
			testing.expect(t, placed.window.body.width >= 0 && placed.window.body.height >= 0)
		}
	}

	nan := math.inf_f32(1) - math.inf_f32(1)
	_, invalid := layout.arrange(&workspace.value, {nan, 600}, layout.default_metrics(20))
	testing.expect(t, invalid.kind == .Invalid_Input)
	errs.destroy(&invalid)
	_, invalid = layout.arrange(&workspace.value, {800, 600}, {drag_threshold = math.inf_f32(1)})
	testing.expect(t, invalid.kind == .Invalid_Input)
	errs.destroy(&invalid)
}

@(test)
test_window_drag_moves_and_reorders :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	hit := layout.hit_test(&geometry, {3, 50})
	testing.expect(t, layout.begin_drag(&workspace.value, hit, {3, 50}))
	layout.drag_move(&workspace.value, {600, 100})
	testing.expect(t, layout.dragging(&workspace.value))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {600, 100}, 5))
	testing.expect(t, !layout.dragging(&workspace.value))
	column, index, ok := layout.find_window(&workspace.value, workspace.first)
	testing.expect(t, ok && column == 1 && index == 0)
	column, index, ok = layout.find_window(&workspace.value, workspace.third)
	testing.expect(t, ok && column == 1 && index == 1)

	geometry = arrange_test_workspace(t, &workspace.value)
	origin := coords.Logical_Point{403, 50}
	hit = layout.hit_test(&geometry, origin)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {600, 590}, 5))
	column, index, ok = layout.find_window(&workspace.value, workspace.first)
	testing.expect(t, ok && column == 1 && index == 1)
	column, index, ok = layout.find_window(&workspace.value, workspace.third)
	testing.expect(t, ok && column == 1 && index == 0)
}

@(test)
test_window_drag_resizes_previous_pair :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	origin := coords.Logical_Point{3, 330}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, hit.window_id == workspace.second)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {3, 380}, 5))
	first := workspace.value.columns[0].windows[0].weight
	second := workspace.value.columns[0].windows[1].weight
	testing.expect(t, first > 1 && second < 1)
	testing.expect(t, abs(first + second - 2) < 0.0001)
}

@(test)
test_first_window_and_column_drag_resizes_next_pair :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	origin := coords.Logical_Point{3, 50}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, hit.window_id == workspace.first)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {3, 100}, 5))
	testing.expect(t, workspace.value.columns[0].windows[0].weight > 1)
	testing.expect(t, workspace.value.columns[0].windows[1].weight < 1)

	origin = {3, 25}
	hit = layout.hit_test(&geometry, origin)
	testing.expect(t, hit.column_id == workspace.left)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {53, 25}, 5))
	testing.expect(t, workspace.value.columns[0].weight > 1)
	testing.expect(t, workspace.value.columns[1].weight < 1)

	origin = {403, 50}
	hit = layout.hit_test(&geometry, origin)
	testing.expect(t, hit.window_id == workspace.third)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, !layout.drag_end(&workspace.value, &geometry, {403, 100}, 5))
	testing.expect(t, workspace.value.columns[1].windows[0].weight == 1)
}

@(test)
test_window_drag_up_into_neighbor_resizes :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	// Window 2's box is at y=325; drag it up into window 1's area while staying
	// below window 1's box (y=46). This is a resize, not a swap, even though the
	// release point leaves window 2's own frame.
	origin := coords.Logical_Point{3, 335}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, hit.window_id == workspace.second)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {3, 200}, 5))
	first := workspace.value.columns[0].windows[0].weight
	second := workspace.value.columns[0].windows[1].weight
	testing.expect(t, first < 1 && second > 1)
	testing.expect(t, abs(first + second - 2) < 0.0001)
	_, index, ok := layout.find_window(&workspace.value, workspace.second)
	testing.expect(t, ok && index == 1)
}

@(test)
test_window_drag_down_past_box_swaps :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	// Window 1's box is at y=46; window 2's box is at y=325. Dropping at y=400
	// is below window 2's box (swap) but still above its frame midpoint, which
	// the old midpoint-based logic treated as a resize.
	origin := coords.Logical_Point{3, 50}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, hit.window_id == workspace.first)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {3, 400}, 5))
	_, first_index, first_ok := layout.find_window(&workspace.value, workspace.first)
	_, second_index, second_ok := layout.find_window(&workspace.value, workspace.second)
	testing.expect(t, first_ok && first_index == 1)
	testing.expect(t, second_ok && second_index == 0)
}

@(test)
test_column_drag_resizes_without_reordering :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	origin := coords.Logical_Point{403, 25}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {10, 25}, 5))
	testing.expect(t, workspace.value.columns[0].id == workspace.left)
	testing.expect(t, workspace.value.columns[1].id == workspace.right)
	testing.expect(t, workspace.value.columns[0].weight < 1)
	testing.expect(t, workspace.value.columns[1].weight > 1)
	testing.expect(t, abs(workspace.value.columns[0].weight + workspace.value.columns[1].weight - 2) < 0.0001)
	column, _, ok := layout.find_window(&workspace.value, workspace.first)
	testing.expect(t, ok && column == 0)
	column, _, ok = layout.find_window(&workspace.value, workspace.third)
	testing.expect(t, ok && column == 1)

	previous_left := workspace.value.columns[0].weight
	geometry = arrange_test_workspace(t, &workspace.value)
	origin = {geometry.columns[1].control.x + 1, 25}
	hit = layout.hit_test(&geometry, origin)
	testing.expect(t, hit.kind == .Column_Control && hit.column_id == workspace.right)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, layout.drag_end(&workspace.value, &geometry, {origin.x + 50, 25}, 5))
	testing.expect(t, workspace.value.columns[0].id == workspace.left)
	testing.expect(t, workspace.value.columns[1].id == workspace.right)
	testing.expect(t, workspace.value.columns[0].weight > previous_left)
	testing.expect(t, workspace.value.columns[1].weight < 1.8)
	testing.expect(t, abs(workspace.value.columns[0].weight + workspace.value.columns[1].weight - 2) < 0.0001)
}

@(test)
test_drag_click_cancel_and_outside_do_not_mutate :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	geometry := arrange_test_workspace(t, &workspace.value)
	origin := coords.Logical_Point{3, 50}
	hit := layout.hit_test(&geometry, origin)
	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, !layout.drag_end(&workspace.value, &geometry, {4, 51}, 5))
	testing.expect(t, workspace.value.columns[0].windows[0].id == workspace.first)

	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	layout.drag_move(&workspace.value, {600, 100})
	layout.drag_cancel(&workspace.value)
	testing.expect(t, !layout.dragging(&workspace.value))
	testing.expect(t, workspace.value.columns[0].windows[0].id == workspace.first)

	testing.expect(t, layout.begin_drag(&workspace.value, hit, origin))
	testing.expect(t, !layout.drag_end(&workspace.value, &geometry, {-100, 100}, 5))
	testing.expect(t, workspace.value.columns[0].windows[0].id == workspace.first)
}

@(test)
test_invalid_weights_are_errors :: proc(t: ^testing.T) {
	workspace := make_workspace(t)
	workspace.value.columns[0].weight = 0
	_, err := layout.arrange(&workspace.value, {800, 600}, layout.default_metrics(20))
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
	workspace.value.columns[0].weight = 1
	workspace.value.columns[0].windows[0].weight = math.inf_f32(1)
	_, err = layout.arrange(&workspace.value, {800, 600}, layout.default_metrics(20))
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)
}
