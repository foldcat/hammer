package layout

import "core:math"

import coords "../coords"
import errs "../errs"

MAX_COLUMNS :: 8
MAX_WINDOWS_PER_COLUMN :: 16

Column_ID :: distinct u64
Window_ID :: distinct u64

Window_Entry :: struct {
	id:     Window_ID,
	weight: f32,
}

Column :: struct {
	id:           Column_ID,
	weight:       f32,
	windows:      [MAX_WINDOWS_PER_COLUMN]Window_Entry,
	window_count: int,
}

Drag_Kind :: enum u8 {
	None,
	Column,
	Window,
}

Drag_State :: struct {
	kind:      Drag_Kind,
	column_id: Column_ID,
	window_id: Window_ID,
	origin:    coords.Logical_Point,
	current:   coords.Logical_Point,
}

Workspace :: struct {
	columns:        [MAX_COLUMNS]Column,
	column_count:   int,
	next_column_id: u64,
	next_window_id: u64,
	drag:           Drag_State,
}

Placed_Window :: struct {
	id:      Window_ID,
	window:  Window,
	control: Rect,
}

Column_Geometry :: struct {
	id:           Column_ID,
	frame:        Rect,
	tag:          Rect,
	control:      Rect,
	windows:      [MAX_WINDOWS_PER_COLUMN]Placed_Window,
	window_count: int,
}

Geometry :: struct {
	bounds:       Rect,
	global_tag:   Rect,
	columns:      [MAX_COLUMNS]Column_Geometry,
	column_count: int,
}

Metrics :: struct {
	global_tag_height: f32,
	column_tag_height: f32,
	window_tag_height: f32,
	pad:               f32,
	border:            f32,
	control_width:     f32,
	drag_threshold:    f32,
}

Hit_Kind :: enum u8 {
	None,
	Global_Tag,
	Column_Control,
	Column_Tag,
	Window_Control,
	Window_Tag,
	Window_Frame,
	Body,
}

Hit :: struct {
	kind:      Hit_Kind,
	column_id: Column_ID,
	window_id: Window_ID,
}

default_metrics :: proc(tag_height: f32) -> Metrics {
	return {
		global_tag_height = tag_height,
		column_tag_height = tag_height,
		window_tag_height = tag_height,
		pad = 2,
		border = 2,
		control_width = tag_height,
		drag_threshold = 5,
	}
}

workspace_init :: proc(workspace: ^Workspace) -> errs.Error {
	workspace^ = {}
	workspace.next_column_id = 1
	workspace.next_window_id = 1
	column_id, err := add_column(workspace)
	if !errs.ok(err) {
		return err
	}
	_, window_err := add_window(workspace, column_id)
	return window_err
}

add_column :: proc(workspace: ^Workspace, index := -1) -> (Column_ID, errs.Error) {
	if workspace.column_count < 0 || workspace.column_count >= MAX_COLUMNS {
		return 0, errs.newf(.Resource_Limit, "layout: at most %d columns are supported", MAX_COLUMNS)
	}
	insertion := index
	if insertion < 0 {
		insertion = workspace.column_count
	}
	if insertion > workspace.column_count {
		return 0, errs.new(.Invalid_Input, "layout: column insertion index is out of range")
	}
	if workspace.next_column_id == 0 {
		return 0, errs.new(.Resource_Limit, "layout: column ID space exhausted")
	}
	for i := workspace.column_count; i > insertion; i -= 1 {
		workspace.columns[i] = workspace.columns[i - 1]
	}
	id := Column_ID(workspace.next_column_id)
	workspace.next_column_id += 1
	workspace.columns[insertion] = {id = id, weight = 1}
	workspace.column_count += 1
	return id, {}
}

add_window :: proc(workspace: ^Workspace, column_id: Column_ID, index := -1) -> (Window_ID, errs.Error) {
	column_index, ok := find_column(workspace, column_id)
	if !ok {
		return 0, errs.new(.NotFound, "layout: cannot add a window to a missing column")
	}
	column := &workspace.columns[column_index]
	if column.window_count < 0 || column.window_count >= MAX_WINDOWS_PER_COLUMN {
		return 0, errs.newf(
			.Resource_Limit,
			"layout: at most %d windows per column are supported",
			MAX_WINDOWS_PER_COLUMN,
		)
	}
	insertion := index
	if insertion < 0 {
		insertion = column.window_count
	}
	if insertion > column.window_count {
		return 0, errs.new(.Invalid_Input, "layout: window insertion index is out of range")
	}
	if workspace.next_window_id == 0 {
		return 0, errs.new(.Resource_Limit, "layout: window ID space exhausted")
	}
	for i := column.window_count; i > insertion; i -= 1 {
		column.windows[i] = column.windows[i - 1]
	}
	id := Window_ID(workspace.next_window_id)
	workspace.next_window_id += 1
	column.windows[insertion] = {id = id, weight = 1}
	column.window_count += 1
	return id, {}
}

find_column :: proc(workspace: ^Workspace, id: Column_ID) -> (int, bool) {
	for column, index in workspace.columns[:workspace.column_count] {
		if column.id == id {
			return index, true
		}
	}
	return 0, false
}

find_window :: proc(workspace: ^Workspace, id: Window_ID) -> (int, int, bool) {
	for column_index in 0 ..< workspace.column_count {
		column := &workspace.columns[column_index]
		for entry, window_index in column.windows[:column.window_count] {
			if entry.id == id {
				return column_index, window_index, true
			}
		}
	}
	return 0, 0, false
}

arrange :: proc(workspace: ^Workspace, size: coords.Logical_Size, metrics: Metrics) -> (Geometry, errs.Error) {
	if !finite_nonneg(size.width) || !finite_nonneg(size.height) {
		return {}, errs.new(.Invalid_Input, "layout: workspace size must be finite and non-negative")
	}
	metric_values := []f32 {
		metrics.global_tag_height,
		metrics.column_tag_height,
		metrics.window_tag_height,
		metrics.pad,
		metrics.border,
		metrics.control_width,
		metrics.drag_threshold,
	}
	for value in metric_values {
		if !finite_nonneg(value) {
			return {}, errs.new(.Invalid_Input, "layout: metrics must be finite and non-negative")
		}
	}
	if workspace.column_count < 0 || workspace.column_count > MAX_COLUMNS {
		return {}, errs.new(.Internal, "layout: invalid column count")
	}

	geometry := Geometry {
		bounds = {0, 0, size.width, size.height},
		global_tag = {0, 0, size.width, min(metrics.global_tag_height, size.height)},
		column_count = workspace.column_count,
	}
	if workspace.column_count == 0 {
		return geometry, {}
	}
	column_weight, weight_err := total_column_weight(workspace)
	if !errs.ok(weight_err) {
		return {}, weight_err
	}
	column_y := geometry.global_tag.height
	available_height := max(0, size.height - column_y)
	available_width := max(0, size.width - metrics.border * f32(workspace.column_count - 1))
	x := f32(0)
	used_weight := f32(0)
	for column_index in 0 ..< workspace.column_count {
		column := &workspace.columns[column_index]
		used_weight += column.weight
		right := size.width
		if column_index < workspace.column_count - 1 {
			right = available_width * used_weight / column_weight + metrics.border * f32(column_index + 1)
		}
		width := max(0, right - x - (metrics.border if column_index < workspace.column_count - 1 else 0))
		frame := Rect{x, column_y, width, available_height}
		tag := inset(frame, metrics.pad)
		tag.height = min(metrics.column_tag_height, tag.height)
		geometry.columns[column_index] = {
			id = column.id,
			frame = frame,
			tag = tag,
			control = control_rect(tag, metrics.control_width),
			window_count = column.window_count,
		}
		arrange_windows(
			column,
			&geometry.columns[column_index],
			metrics,
		)
		x = right
	}
	return geometry, {}
}

arrange_windows :: proc(column: ^Column, geometry: ^Column_Geometry, metrics: Metrics) {
	if column.window_count == 0 {
		return
	}
	total_weight := f32(0)
	for entry in column.windows[:column.window_count] {
		total_weight += entry.weight
	}
	window_top := geometry.tag.y + geometry.tag.height + metrics.border
	column_bottom := geometry.frame.y + geometry.frame.height
	available_height := max(
		0,
		column_bottom - window_top - metrics.border * f32(column.window_count - 1),
	)
	y := window_top
	used_weight := f32(0)
	for entry, window_index in column.windows[:column.window_count] {
		used_weight += entry.weight
		bottom := column_bottom
		if window_index < column.window_count - 1 {
			bottom = window_top + available_height * used_weight / total_weight + metrics.border * f32(window_index + 1)
		}
		height := max(0, bottom - y - (metrics.border if window_index < column.window_count - 1 else 0))
		frame := Rect{geometry.frame.x, y, geometry.frame.width, height}
		win, _ := window({frame.width, frame.height}, metrics.window_tag_height, metrics.pad)
		win.frame = translate(win.frame, frame.x, frame.y)
		win.tag = translate(win.tag, frame.x, frame.y)
		win.body = translate(win.body, frame.x, frame.y)
		geometry.windows[window_index] = {
			id = entry.id,
			window = win,
			control = control_rect(win.tag, metrics.control_width),
		}
		y = bottom
	}
}

total_column_weight :: proc(workspace: ^Workspace) -> (f32, errs.Error) {
	total := f32(0)
	for column_index in 0 ..< workspace.column_count {
		column := &workspace.columns[column_index]
		if !finite_positive(column.weight) || column.window_count < 0 || column.window_count > MAX_WINDOWS_PER_COLUMN {
			return 0, errs.new(.Invalid_Input, "layout: invalid column state")
		}
		for entry in column.windows[:column.window_count] {
			if !finite_positive(entry.weight) {
				return 0, errs.new(.Invalid_Input, "layout: window weights must be finite and positive")
			}
		}
		total += column.weight
	}
	if !finite_positive(total) {
		return 0, errs.new(.Invalid_Input, "layout: column weights must have a finite positive sum")
	}
	return total, {}
}

finite_positive :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value) && value > 0
}

inset :: proc(rect: Rect, pad: f32) -> Rect {
	left := min(pad, rect.width)
	right := min(pad, rect.width - left)
	top := min(pad, rect.height)
	bottom := min(pad, rect.height - top)
	return {
		rect.x + left,
		rect.y + top,
		rect.width - left - right,
		rect.height - top - bottom,
	}
}

translate :: proc(rect: Rect, x, y: f32) -> Rect {
	return {rect.x + x, rect.y + y, rect.width, rect.height}
}

control_rect :: proc(tag: Rect, width: f32) -> Rect {
	return {tag.x, tag.y, min(width, tag.width), tag.height}
}

contains :: proc(rect: Rect, point: coords.Logical_Point) -> bool {
	return rect.width > 0 && rect.height > 0 &&
		point.x >= rect.x && point.x < rect.x + rect.width &&
		point.y >= rect.y && point.y < rect.y + rect.height
}

hit_test :: proc(geometry: ^Geometry, point: coords.Logical_Point) -> Hit {
	if math.is_nan(point.x) || math.is_inf(point.x) || math.is_nan(point.y) || math.is_inf(point.y) {
		return {}
	}
	if contains(geometry.global_tag, point) {
		return {kind = .Global_Tag}
	}
	for column_index in 0 ..< geometry.column_count {
		column := &geometry.columns[column_index]
		if contains(column.control, point) {
			return {kind = .Column_Control, column_id = column.id}
		}
		if contains(column.tag, point) {
			return {kind = .Column_Tag, column_id = column.id}
		}
		for placed in column.windows[:column.window_count] {
			if contains(placed.control, point) {
				return {kind = .Window_Control, column_id = column.id, window_id = placed.id}
			}
			if contains(placed.window.tag, point) {
				return {kind = .Window_Tag, column_id = column.id, window_id = placed.id}
			}
			if contains(placed.window.body, point) {
				return {kind = .Body, column_id = column.id, window_id = placed.id}
			}
			if contains(placed.window.frame, point) {
				return {kind = .Window_Frame, column_id = column.id, window_id = placed.id}
			}
		}
	}
	return {}
}

begin_drag :: proc(workspace: ^Workspace, hit: Hit, point: coords.Logical_Point) -> bool {
	if math.is_nan(point.x) || math.is_inf(point.x) || math.is_nan(point.y) || math.is_inf(point.y) {
		return false
	}
	#partial switch hit.kind {
	case .Column_Control:
		if _, ok := find_column(workspace, hit.column_id); !ok {
			return false
		}
		workspace.drag = {kind = .Column, column_id = hit.column_id, origin = point, current = point}
		return true
	case .Window_Control:
		if _, _, ok := find_window(workspace, hit.window_id); !ok {
			return false
		}
		workspace.drag = {
			kind = .Window,
			column_id = hit.column_id,
			window_id = hit.window_id,
			origin = point,
			current = point,
		}
		return true
	}
	return false
}

dragging :: proc(workspace: ^Workspace) -> bool {
	return workspace.drag.kind != .None
}

drag_move :: proc(workspace: ^Workspace, point: coords.Logical_Point) {
	if !dragging(workspace) || math.is_nan(point.x) || math.is_inf(point.x) || math.is_nan(point.y) || math.is_inf(point.y) {
		return
	}
	workspace.drag.current = point
}

drag_cancel :: proc(workspace: ^Workspace) {
	workspace.drag = {}
}

drag_end :: proc(workspace: ^Workspace, geometry: ^Geometry, point: coords.Logical_Point, threshold: f32) -> bool {
	drag := workspace.drag
	drag_cancel(workspace)
	if drag.kind == .None || math.is_nan(point.x) || math.is_inf(point.x) || math.is_nan(point.y) || math.is_inf(point.y) {
		return false
	}
	if abs(point.x - drag.origin.x) < threshold && abs(point.y - drag.origin.y) < threshold {
		return false
	}
	switch drag.kind {
	case .None:
		return false
	case .Column:
		return end_column_drag(workspace, geometry, drag, point)
	case .Window:
		return end_window_drag(workspace, geometry, drag, point)
	}
	return false
}

end_column_drag :: proc(workspace: ^Workspace, geometry: ^Geometry, drag: Drag_State, point: coords.Logical_Point) -> bool {
	source_index, ok := find_column(workspace, drag.column_id)
	if !ok {
		return false
	}
	target_index := column_at(geometry, point)
	if target_index >= 0 && target_index != source_index {
		target_column := geometry.columns[target_index]
		insertion := target_index
		if point.x >= target_column.frame.x + target_column.frame.width / 2 {
			insertion += 1
		}
		return move_column(workspace, source_index, insertion)
	}
	if !contains(geometry.columns[source_index].frame, point) {
		return false
	}
	delta := point.x - drag.origin.x
	if source_index == 0 {
		if workspace.column_count < 2 {
			return false
		}
		available := geometry.columns[0].frame.width + geometry.columns[1].frame.width
		return resize_columns(workspace, 0, 1, delta, available)
	}
	available := geometry.columns[source_index - 1].frame.width + geometry.columns[source_index].frame.width
	return resize_columns(workspace, source_index - 1, source_index, delta, available)
}

end_window_drag :: proc(workspace: ^Workspace, geometry: ^Geometry, drag: Drag_State, point: coords.Logical_Point) -> bool {
	source_column, source_window, ok := find_window(workspace, drag.window_id)
	if !ok {
		return false
	}
	target_column := column_at(geometry, point)
	if target_column < 0 {
		return false
	}
	insertion := window_insertion(geometry.columns[target_column], point.y)
	if target_column != source_column {
		return move_window(workspace, source_column, source_window, target_column, insertion)
	}
	if insertion != source_window && insertion != source_window + 1 {
		return move_window(workspace, source_column, source_window, target_column, insertion)
	}
	column := &workspace.columns[source_column]
	if !contains(geometry.columns[source_column].windows[source_window].window.frame, point) {
		return false
	}
	delta := point.y - drag.origin.y
	if source_window == 0 {
		if column.window_count < 2 {
			return false
		}
		available := geometry.columns[source_column].windows[0].window.frame.height +
			geometry.columns[source_column].windows[1].window.frame.height
		return resize_windows(workspace, source_column, 0, 1, delta, available)
	}
	available := geometry.columns[source_column].windows[source_window - 1].window.frame.height +
		geometry.columns[source_column].windows[source_window].window.frame.height
	return resize_windows(workspace, source_column, source_window - 1, source_window, delta, available)
}

column_at :: proc(geometry: ^Geometry, point: coords.Logical_Point) -> int {
	for column, index in geometry.columns[:geometry.column_count] {
		if point.x >= column.frame.x && point.x < column.frame.x + column.frame.width &&
			point.y >= column.frame.y && point.y <= column.frame.y + column.frame.height {
			return index
		}
	}
	return -1
}

window_insertion :: proc(column: Column_Geometry, y: f32) -> int {
	for index in 0 ..< column.window_count {
		placed := column.windows[index]
		if y < placed.window.frame.y + placed.window.frame.height / 2 {
			return index
		}
	}
	return column.window_count
}

move_column :: proc(workspace: ^Workspace, source, insertion: int) -> bool {
	if source < 0 || source >= workspace.column_count || insertion < 0 || insertion > workspace.column_count {
		return false
	}
	target := insertion
	if target > source {
		target -= 1
	}
	if target == source {
		return false
	}
	column := workspace.columns[source]
	for i := source; i + 1 < workspace.column_count; i += 1 {
		workspace.columns[i] = workspace.columns[i + 1]
	}
	workspace.column_count -= 1
	for i := workspace.column_count; i > target; i -= 1 {
		workspace.columns[i] = workspace.columns[i - 1]
	}
	workspace.columns[target] = column
	workspace.column_count += 1
	return true
}

move_window :: proc(workspace: ^Workspace, source_column, source_window, target_column, insertion: int) -> bool {
	if source_column < 0 || source_column >= workspace.column_count ||
		target_column < 0 || target_column >= workspace.column_count {
		return false
	}
	source := &workspace.columns[source_column]
	target := &workspace.columns[target_column]
	if source_window < 0 || source_window >= source.window_count || insertion < 0 || insertion > target.window_count {
		return false
	}
	if target_column != source_column && target.window_count >= MAX_WINDOWS_PER_COLUMN {
		return false
	}
	adjusted := insertion
	if target_column == source_column && adjusted > source_window {
		adjusted -= 1
	}
	if target_column == source_column && adjusted == source_window {
		return false
	}
	entry := source.windows[source_window]
	for i := source_window; i + 1 < source.window_count; i += 1 {
		source.windows[i] = source.windows[i + 1]
	}
	source.window_count -= 1
	target = &workspace.columns[target_column]
	for i := target.window_count; i > adjusted; i -= 1 {
		target.windows[i] = target.windows[i - 1]
	}
	target.windows[adjusted] = entry
	target.window_count += 1
	return true
}

resize_columns :: proc(workspace: ^Workspace, previous, current: int, delta, available: f32) -> bool {
	if previous < 0 || current != previous + 1 || current >= workspace.column_count || available <= 0 {
		return false
	}
	return resize_weights(
		&workspace.columns[previous].weight,
		&workspace.columns[current].weight,
		delta,
		available,
	)
}

resize_windows :: proc(workspace: ^Workspace, column, previous, current: int, delta, available: f32) -> bool {
	if column < 0 || column >= workspace.column_count {
		return false
	}
	windows := &workspace.columns[column]
	if previous < 0 || current != previous + 1 || current >= windows.window_count || available <= 0 {
		return false
	}
	return resize_weights(&windows.windows[previous].weight, &windows.windows[current].weight, delta, available)
}

resize_weights :: proc(previous, current: ^f32, delta, available: f32) -> bool {
	total := previous^ + current^
	minimum := total * 0.1
	next := clamp(previous^ + delta * total / available, minimum, total - minimum)
	if next == previous^ {
		return false
	}
	previous^ = next
	current^ = total - next
	return true
}

remove_window :: proc(workspace: ^Workspace, id: Window_ID) -> bool {
	column_index, window_index, ok := find_window(workspace, id)
	if !ok {
		return false
	}
	column := &workspace.columns[column_index]
	for index := window_index; index + 1 < column.window_count; index += 1 {
		column.windows[index] = column.windows[index + 1]
	}
	column.window_count -= 1
	column.windows[column.window_count] = {}
	if workspace.drag.window_id == id {
		drag_cancel(workspace)
	}
	return true
}
