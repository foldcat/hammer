package main

import "core:log"
import "core:math"
import "core:time"

import sapp "sokol:app"

import config "core/config"
import coords "core/coords"
import editing "core/editing"
import errs "core/errs"
import input "core/input"
import layout "core/layout"
import mouse "core/mouse"
import platform "platform"
import rope "core/rope"
import scroll "core/scroll"
import tagstate "core/tag"
import txn "core/txn"
import view "core/view"

BODY_TARGET_BASE :: u64(3000)

Mouse_Text_Target :: struct {
	id: mouse.Target_ID,
	kind: Text_Kind,
	window_id: layout.Window_ID,
	column_id: layout.Column_ID,
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	delayed_paste: ^editing.Delayed_Paste,
	delayed_cut: ^editing.Delayed_Cut,
	buffer_id: u64,
	generation: u64,
	item: ^view.View,
	tag: ^tagstate.State,
}

Mouse_Chord_Runtime :: struct {
	active: bool,
	target: mouse.Target_ID,
	operation: mouse.Chord,
	request_id: u64,
	transaction: txn.Transaction_ID,
	before: txn.Selection,
}

mouse_epoch := time.tick_now()

mouse_now_ms :: proc() -> u64 {
	elapsed := time.duration_milliseconds(time.tick_since(mouse_epoch))
	return u64(max(0, int(elapsed)))
}

editor_body_target_id :: proc(window_id: layout.Window_ID) -> mouse.Target_ID {
	return mouse.Target_ID(BODY_TARGET_BASE + u64(window_id))
}

editor_active_text_target :: proc() -> Mouse_Text_Target {
	target := Mouse_Text_Target{kind = editor.active_text_kind, generation = DEFAULT_BUFFER_GENERATION}
	switch editor.active_text_kind {
	case .Body:
		item := editor_active_view()
		if item == nil {
			return {}
		}
		target.id = editor_body_target_id(item.window_id)
		target.window_id = item.window_id
		target.doc = &editor_buffer_for_view(item).doc
		target.selection = &item.selection
		target.delayed_paste = &item.delayed_paste
		target.delayed_cut = &item.delayed_cut
		target.buffer_id = u64(item.buffer_id)
		target.generation = editor_buffer_for_view(item).generation
		target.item = item
	case .Global_Tag:
		target.id = mouse.Target_ID(GLOBAL_TAG_BUFFER_ID)
		target.doc = &editor.global_tag.doc
		target.selection = &editor.global_tag.selection
		target.delayed_paste = &editor.global_tag.delayed_paste
		target.delayed_cut = &editor.global_tag.delayed_cut
		target.buffer_id = GLOBAL_TAG_BUFFER_ID
		target.tag = &editor.global_tag
	case .Column_Tag:
		index, ok := layout.find_column(&editor.workspace, editor.active_column)
		if !ok {
			return {}
		}
		tag := &editor.column_tags[index]
		target.id = mouse.Target_ID(COLUMN_TAG_BUFFER_BASE + u64(editor.active_column))
		target.column_id = editor.active_column
		target.doc = &tag.doc
		target.selection = &tag.selection
		target.delayed_paste = &tag.delayed_paste
		target.delayed_cut = &tag.delayed_cut
		target.buffer_id = COLUMN_TAG_BUFFER_BASE + u64(editor.active_column)
		target.tag = tag
	case .Window_Tag:
		item := editor_active_view()
		if item == nil {
			return {}
		}
		target.id = mouse.Target_ID(WINDOW_TAG_BUFFER_BASE + u64(item.window_id))
		target.window_id = item.window_id
		target.column_id = editor.active_column
		target.doc = &item.tag.doc
		target.selection = &item.tag.selection
		target.delayed_paste = &item.tag.delayed_paste
		target.delayed_cut = &item.tag.delayed_cut
		target.buffer_id = WINDOW_TAG_BUFFER_BASE + u64(item.window_id)
		target.tag = &item.tag
		target.item = item
	}
	return target
}

editor_text_target_by_id :: proc(id: mouse.Target_ID) -> Mouse_Text_Target {
	if id == mouse.Target_ID(GLOBAL_TAG_BUFFER_ID) {
		return Mouse_Text_Target{
			id = id,
			kind = .Global_Tag,
			doc = &editor.global_tag.doc,
			selection = &editor.global_tag.selection,
			delayed_paste = &editor.global_tag.delayed_paste,
			delayed_cut = &editor.global_tag.delayed_cut,
			buffer_id = GLOBAL_TAG_BUFFER_ID,
			generation = DEFAULT_BUFFER_GENERATION,
			tag = &editor.global_tag,
		}
	}
	if u64(id) > BODY_TARGET_BASE {
		window_id := layout.Window_ID(u64(id) - BODY_TARGET_BASE)
		item, found := view.find(&editor.views, window_id)
		if !found {
			return {}
		}
		return Mouse_Text_Target{
			id = id,
			kind = .Body,
			window_id = window_id,
			doc = &editor_buffer_for_view(item).doc,
			selection = &item.selection,
			delayed_paste = &item.delayed_paste,
			delayed_cut = &item.delayed_cut,
			buffer_id = u64(item.buffer_id),
			generation = editor_buffer_for_view(item).generation,
			item = item,
		}
	}
	if u64(id) > WINDOW_TAG_BUFFER_BASE && u64(id) < BODY_TARGET_BASE {
		window_id := layout.Window_ID(u64(id) - WINDOW_TAG_BUFFER_BASE)
		item, found := view.find(&editor.views, window_id)
		if !found {
			return {}
		}
		return Mouse_Text_Target{
			id = id,
			kind = .Window_Tag,
			window_id = window_id,
			doc = &item.tag.doc,
			selection = &item.tag.selection,
			delayed_paste = &item.tag.delayed_paste,
			delayed_cut = &item.tag.delayed_cut,
			buffer_id = WINDOW_TAG_BUFFER_BASE + u64(window_id),
			generation = DEFAULT_BUFFER_GENERATION,
			tag = &item.tag,
			item = item,
		}
	}
	if u64(id) > COLUMN_TAG_BUFFER_BASE && u64(id) < WINDOW_TAG_BUFFER_BASE {
		column_id := layout.Column_ID(u64(id) - COLUMN_TAG_BUFFER_BASE)
		index, found := layout.find_column(&editor.workspace, column_id)
		if !found {
			return {}
		}
		tag := &editor.column_tags[index]
		return Mouse_Text_Target{
			id = id,
			kind = .Column_Tag,
			column_id = column_id,
			doc = &tag.doc,
			selection = &tag.selection,
			delayed_paste = &tag.delayed_paste,
			delayed_cut = &tag.delayed_cut,
			buffer_id = COLUMN_TAG_BUFFER_BASE + u64(column_id),
			generation = DEFAULT_BUFFER_GENERATION,
			tag = tag,
		}
	}
	return {}
}

editor_target_body :: proc(target: Mouse_Text_Target) -> Mouse_Text_Target {
	if target.window_id == 0 {
		return {}
	}
	return editor_text_target_by_id(editor_body_target_id(target.window_id))
}

editor_target_rect :: proc(geometry: ^layout.Geometry, target: Mouse_Text_Target) -> (layout.Rect, bool) {
	switch target.kind {
	case .Global_Tag:
		rect := geometry.global_tag
		pad := workspace_metrics().pad
		rect.x += pad
		rect.y += pad
		rect.width = max(0, rect.width - 2 * pad)
		return rect, true
	case .Column_Tag:
		for column_index in 0 ..< geometry.column_count {
			column := &geometry.columns[column_index]
			if column.id == target.column_id {
				return tag_content_rect(column.tag, column.control), true
			}
		}
	case .Window_Tag, .Body:
		for column_index in 0 ..< geometry.column_count {
			column := &geometry.columns[column_index]
			for placed in column.windows[:column.window_count] {
				if placed.id != target.window_id {
					continue
				}
				if target.kind == .Window_Tag {
					return tag_content_rect(placed.window.tag, placed.control), true
				}
				_, _, text := editor_body_parts(target.item, target.doc, placed.window.body)
				return text, true
			}
		}
	}
	return {}, false
}

MAX_HORIZONTAL_SCROLL_OFFSET :: f32(1024 * 1024)

// editor_selection_gesture_active reports whether the primary button is held
// in Select mode, i.e. the user is dragging to extend a text selection.
editor_selection_gesture_active :: proc() -> bool {
	return mouse.active(&editor.mouse_gesture) &&
		editor.mouse_gesture.mode == .Select &&
		.Left in editor.mouse_gesture.buttons
}

// editor_continue_selection_at re-hits the held selection gesture at a logical
// position after the viewport moved under the pointer (wheel scroll). It keeps
// the anchor fixed and extends the active edge to whatever text now sits there.
editor_continue_selection_at :: proc(pos: coords.Logical_Point) {
	target := editor_text_target_by_id(editor.mouse_gesture.target)
	if !editor_mouse_target_current(target) {
		editor_cancel_pointer_gesture()
		return
	}
	hit, hit_ok := editor_mouse_hit(target, pos, true)
	if !hit_ok {
		editor_cancel_pointer_gesture()
		return
	}
	target.selection.affinity = hit.affinity
	action := mouse.move(&editor.mouse_gesture, hit.offset, pos, editor.mouse_gesture.buttons)
	editor_dispatch_mouse_action(action)
}

editor_scroll :: proc(event: input.Scroll) {
	valid_dx := event.dx != 0 && !math.is_nan(event.dx) && !math.is_inf(event.dx)
	valid_dy := event.dy != 0 && !math.is_nan(event.dy) && !math.is_inf(event.dy)
	if !valid_dx && !valid_dy {
		return
	}
	geometry, _, ok := current_layout()
	if !ok {
		return
	}
	area := layout.hit_test(&geometry, event.pos)
	if area.kind != .Body {
		return
	}
	item, found := view.find(&editor.views, area.window_id)
	if !found {
		return
	}
	win, win_found := window_for_id(&geometry, area.window_id)
	if !win_found {
		return
	}
	// A held primary-button selection keeps following the pointer as the
	// viewport scrolls; any other gesture is cancelled by scrolling.
	selecting := editor_selection_gesture_active() &&
		editor.mouse_gesture.target == editor_body_target_id(area.window_id)
	if !selecting {
		editor_cancel_pointer_gesture()
		editor_cancel_close_review()
	}
	if valid_dx {
		if item.wrap_mode == .Soft {
			item.horizontal_offset = 0
		} else {
			step := coords.points_to_logical_px(state.dpi.points) * 4
			item.horizontal_offset = clamp(item.horizontal_offset + event.dx * step, 0, MAX_HORIZONTAL_SCROLL_OFFSET)
		}
		log.infof("view: horizontal scroll window=%d offset=%.2f", u64(item.window_id), item.horizontal_offset)
	}
	if valid_dy {
		doc := &editor_buffer_for_view(item).doc
		_, _, text := editor_body_parts(item, doc, win.body)
		editor_wheel_vertical(item, doc, text, event.dy)
	}
	if selecting {
		editor_continue_selection_at(event.pos)
	}
}

editor_mouse_hit :: proc(target: Mouse_Text_Target, pos: coords.Logical_Point, clamp_to_visible: bool) -> (Text_Hit, bool) {
	geometry, _, ok := current_layout()
	if !ok || target.doc == nil || target.selection == nil {
		return {}, false
	}
	rect, rect_ok := editor_target_rect(&geometry, target)
	if !rect_ok {
		return {}, false
	}
	first_line := rope.Line_Index(0)
	first_row := 0
	wrap_mode := config.Wrap_Mode.Truncate
	horizontal_offset: ^f32
	if target.kind == .Body && target.item != nil {
		editor_normalize_view_origin(target.item, target.doc, rect)
		first_line = target.item.first_line
		first_row = target.item.first_row
		wrap_mode = target.item.wrap_mode
		horizontal_offset = &target.item.horizontal_offset
	}
	return text_hit_test(pos, clamp_to_visible, rect, first_line, first_row, wrap_mode, horizontal_offset, target.doc)
}

editor_mouse_target_current :: proc(target: Mouse_Text_Target) -> bool {
	return target.doc != nil && target.generation == editor.mouse_generation &&
		txn.doc_revision(target.doc) == editor.mouse_revision
}

editor_pointer_down :: proc(event: input.Pointer_Down) {
	geometry, _, geometry_ok := current_layout()
	if !geometry_ok {
		return
	}
	area := layout.hit_test(&geometry, event.pos)
	if scroll.active(&editor.scrollbar) && area.kind != .Body {
		editor_cancel_pointer_gesture()
		return
	}
	if area.kind == .Body {
		if win, found := window_for_id(&geometry, area.window_id); found &&
			editor_scrollbar_pointer_down(event, area, win.body) {
			return
		}
	}
	if mouse.active(&editor.mouse_gesture) {
		target := editor_text_target_by_id(editor.mouse_gesture.target)
		if !editor_mouse_target_current(target) {
			editor_cancel_pointer_gesture()
			return
		}
		offset := editor.mouse_gesture.active
		editor_dispatch_mouse_action(mouse.down(&editor.mouse_gesture, event.button, target.id, offset, event.pos, event.modifiers, mouse_now_ms()))
		return
	}
	if event.button == .Left && event.modifiers != {} && event.modifiers != {.Shift} &&
		event.modifiers != {.Ctrl} && event.modifiers != {.Alt} {
		return
	}
	if area.kind == .Window_Control {
		editor_activate_window(area.window_id)
	}
	if event.button == .Left && .Ctrl not_in event.modifiers && .Alt not_in event.modifiers &&
		layout.begin_drag(&editor.workspace, area, event.pos) {
		editor.typing_group = 0
		editor_cancel_close_review()
		return
	}
	#partial switch area.kind {
	case .Global_Tag:
		editor_activate_text(.Global_Tag)
	case .Column_Tag:
		editor_activate_text(.Column_Tag, area.column_id)
	case .Window_Tag:
		editor_activate_window(area.window_id)
		editor_activate_text(.Window_Tag, area.column_id)
	case .Body:
		editor_activate_window(area.window_id)
	case:
		return
	}
	target := editor_active_text_target()
	hit, hit_ok := editor_mouse_hit(target, event.pos, false)
	if !hit_ok {
		return
	}
	target.selection.affinity = hit.affinity
	editor.typing_group = 0
	editor_cancel_close_review()
	editor.mouse_revision = txn.doc_revision(target.doc)
	editor.mouse_generation = target.generation
	action := mouse.down(&editor.mouse_gesture, event.button, target.id, hit.offset, event.pos, event.modifiers, mouse_now_ms())
	editor_dispatch_mouse_action(action)
}

editor_update_mouse_cursor :: proc(pos: coords.Logical_Point) {
	cursor := sapp.Mouse_Cursor.DEFAULT
	if geometry, _, ok := current_layout(); ok {
		#partial switch layout.hit_test(&geometry, pos).kind {
		case .Column_Control:
			cursor = .RESIZE_EW
		case .Window_Control:
			cursor = .RESIZE_NS
		}
	}
	sapp.set_mouse_cursor(cursor)
}

editor_pointer_move :: proc(event: input.Pointer_Move) {
	editor_update_mouse_cursor(event.pos)
	if editor_scrollbar_pointer_move(event) {
		return
	}
	if layout.dragging(&editor.workspace) {
		if .Left not_in event.buttons {
			layout.drag_cancel(&editor.workspace)
			return
		}
		layout.drag_move(&editor.workspace, event.pos)
		return
	}
	if !mouse.active(&editor.mouse_gesture) {
		return
	}
	target := editor_text_target_by_id(editor.mouse_gesture.target)
	if !editor_mouse_target_current(target) {
		editor_cancel_pointer_gesture()
		return
	}
	hit, hit_ok := editor_mouse_hit(target, event.pos, true)
	if !hit_ok {
		editor_cancel_pointer_gesture()
		return
	}
	target.selection.affinity = hit.affinity
	action := mouse.move(&editor.mouse_gesture, hit.offset, event.pos, event.buttons)
	editor_dispatch_mouse_action(action)
}

editor_pointer_up :: proc(event: input.Pointer_Up) {
	if editor_scrollbar_pointer_up(event) {
		return
	}
	if event.button == .Left && layout.dragging(&editor.workspace) {
		kind := editor.workspace.drag.kind
		window_id := editor.workspace.drag.window_id
		column_id := editor.workspace.drag.column_id
		geometry, _, ok := current_layout()
		if ok {
			metrics := workspace_metrics()
			if layout.drag_end(&editor.workspace, &geometry, event.pos, metrics.drag_threshold) {
				editor_log_layout_drag(kind, column_id, window_id)
			}
		} else {
			layout.drag_cancel(&editor.workspace)
		}
		return
	}
	if !mouse.active(&editor.mouse_gesture) {
		return
	}
	target := editor_text_target_by_id(editor.mouse_gesture.target)
	if !editor_mouse_target_current(target) {
		editor_cancel_pointer_gesture()
		return
	}
	hit, hit_ok := editor_mouse_hit(target, event.pos, true)
	if !hit_ok {
		editor_cancel_pointer_gesture()
		return
	}
	target.selection.affinity = hit.affinity
	action := mouse.up(&editor.mouse_gesture, event.button, hit.offset, event.pos, mouse_now_ms())
	editor_dispatch_mouse_action(action)
}

editor_dispatch_mouse_action :: proc(action: mouse.Action) {
	switch a in action {
	case mouse.Select_Start:
		target := editor_text_target_by_id(a.target)
		if target.selection == nil {
			editor_cancel_pointer_gesture()
			return
		}
		anchor := a.offset
		if a.extend {
			anchor = target.selection.anchor
		}
		target.selection^ = txn.Selection{anchor = anchor, active = a.offset, affinity = target.selection.affinity}
		editor.mouse_expanded = false
		if a.expand {
			range, err := mouse.double_click_range(target.doc, a.offset)
			if !errs.ok(err) {
				editor_report(err)
				return
			}
			target.selection.anchor = range.start
			target.selection.active = range.end
			editor.mouse_expanded = range.start != range.end
		}
	case mouse.Select_Update:
		target := editor_text_target_by_id(a.target)
		if target.selection == nil {
			editor_cancel_pointer_gesture()
			return
		}
		if a.drag_started && editor.mouse_expanded {
			if a.offset < target.selection.anchor {
				target.selection.anchor = target.selection.active
			}
			editor.mouse_expanded = false
		}
		target.selection.active = a.offset
		target.selection.visual_column = 0
	case mouse.Select_Finish:
		target := editor_text_target_by_id(a.target)
		if target.selection == nil {
			return
		}
		if !a.chorded {
			target.selection.active = a.active
			target.selection.visual_column = 0
		}
		editor_capture_mouse_argument(target)
		editor.mouse_expanded = false
	case mouse.Execute:
		editor_execute_mouse(a)
	case mouse.Look:
		editor_look_mouse(a)
	case mouse.Chord_Cut:
		editor_start_mouse_chord(a.target, .Cut)
	case mouse.Chord_Paste:
		editor_start_mouse_chord(a.target, .Paste)
	case mouse.Undo_Cut:
		editor_undo_mouse_chord(a.target, .Cut)
	case mouse.Undo_Paste:
		editor_undo_mouse_chord(a.target, .Paste)
	case mouse.Cancel:
		editor_cancel_mouse_chord()
		editor.mouse_expanded = false
	}
}

editor_cancel_pointer_gesture :: proc() {
	mouse.cancel(&editor.mouse_gesture)
	scroll.cancel(&editor.scrollbar)
	editor_cancel_mouse_chord()
	editor.mouse_expanded = false
	editor.mouse_revision = 0
	editor.mouse_generation = 0
	layout.drag_cancel(&editor.workspace)
}


editor_copy_target :: proc(target: Mouse_Text_Target) -> bool {
	editor_poll_clipboard()
	if target.doc == nil || target.selection == nil {
		return false
	}
	range := editing.selection_range(target.selection^)
	if range.start == range.end {
		return false
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return false
	}
	request_id := editor_next_clipboard_request_id()
	if err := editor_start_clipboard_write(target.doc, range, request_id); !errs.ok(err) {
		editor_report(err)
		return false
	}
	return true
}

editor_cut_target :: proc(target: Mouse_Text_Target) -> bool {
	editor_poll_clipboard()
	if target.doc == nil || target.selection == nil || target.delayed_cut == nil {
		return false
	}
	range := editing.selection_range(target.selection^)
	if range.start == range.end {
		return false
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return false
	}
	request_id := editor_next_clipboard_request_id()
	if err := editing.delayed_cut_begin(
		target.delayed_cut,
		target.doc,
		target.selection,
		target.buffer_id,
		target.generation,
		u64(request_id),
	); !errs.ok(err) {
		editor_report(err)
		return false
	}
	if err := editor_start_clipboard_write(target.doc, range, request_id); !errs.ok(err) {
		editor_cancel_delayed_cut(target.delayed_cut)
		editor_report(err)
		return false
	}
	return true
}

editor_paste_target :: proc(target: Mouse_Text_Target) -> bool {
	editor_poll_clipboard()
	if target.doc == nil || target.selection == nil || target.delayed_paste == nil {
		return false
	}
	if !editor_clipboard_available() {
		editor_report(errs.new(.Unsupported, "clipboard: native service is unavailable"))
		return false
	}
	request_id := editor_next_clipboard_request_id()
	if err := editing.delayed_paste_begin(
		target.delayed_paste,
		target.doc,
		target.selection,
		target.buffer_id,
		target.generation,
		u64(request_id),
	); !errs.ok(err) {
		editor_report(err)
		return false
	}
	if err := services.clipboard.start(services.user, {
		id = request_id,
		selection = .Clipboard,
		operation = .Read,
	}); !errs.ok(err) {
		editor_cancel_delayed_paste(target.delayed_paste)
		editor_report(err)
		return false
	}
	return true
}

editor_start_mouse_chord :: proc(id: mouse.Target_ID, operation: mouse.Chord) {
	target := editor_text_target_by_id(id)
	if target.selection == nil || (operation == .Cut && target.selection.anchor == target.selection.active) {
		return
	}
	editor_cancel_mouse_chord()
	editor.mouse_chord = {
		active = true,
		target = id,
		operation = operation,
		before = target.selection^,
	}
	started := false
	switch operation {
	case .None:
	case .Cut:
		started = editor_cut_target(target)
	case .Paste:
		started = editor_paste_target(target)
	}
	if !started {
		editor.mouse_chord = {}
		return
	}
	if operation == .Cut && target.delayed_cut.pending {
		editor.mouse_chord.request_id = target.delayed_cut.target.request_id
	} else if operation == .Paste && target.delayed_paste.pending {
		editor.mouse_chord.request_id = target.delayed_paste.target.request_id
	}
	log.infof("mouse: chord %v started target=%d request=%d", operation, u64(id), editor.mouse_chord.request_id)
}

editor_cancel_mouse_chord :: proc() {
	runtime := editor.mouse_chord
	if !runtime.active {
		return
	}
	target := editor_text_target_by_id(runtime.target)
	switch runtime.operation {
	case .None:
	case .Cut:
		if target.delayed_cut != nil && target.delayed_cut.pending && target.delayed_cut.target.request_id == runtime.request_id {
			editor_cancel_delayed_cut(target.delayed_cut)
		}
	case .Paste:
		if target.delayed_paste != nil && target.delayed_paste.pending && target.delayed_paste.target.request_id == runtime.request_id {
			editor_cancel_delayed_paste(target.delayed_paste)
		}
	}
	editor.mouse_chord = {}
}

editor_undo_mouse_chord :: proc(id: mouse.Target_ID, operation: mouse.Chord) {
	runtime := editor.mouse_chord
	if !runtime.active || runtime.target != id || runtime.operation != operation {
		return
	}
	target := editor_text_target_by_id(id)
	if target.doc == nil || target.selection == nil {
		editor.mouse_chord = {}
		return
	}
	if runtime.request_id != 0 {
		pending := false
		if operation == .Cut && target.delayed_cut != nil {
			pending = target.delayed_cut.pending && target.delayed_cut.target.request_id == runtime.request_id
		} else if operation == .Paste && target.delayed_paste != nil {
			pending = target.delayed_paste.pending && target.delayed_paste.target.request_id == runtime.request_id
		}
		if pending {
			editor_cancel_mouse_chord()
			log.infof("mouse: reversed %v chord canceled its pending clipboard request", operation)
			return
		}
	}
	if runtime.transaction == 0 || target.doc.current != runtime.transaction {
		editor.mouse_chord = {}
		editor_report(errs.new(.Conflict, "mouse: chord transaction changed; refusing to undo an unrelated edit"))
		return
	}
	_, err := txn.doc_undo(target.doc)
	if !errs.ok(err) {
		editor.mouse_chord = {}
		editor_report(err)
		return
	}
	target.selection^ = runtime.before
	target.selection.visual_column = 0
	if target.kind == .Body {
		editor_finish_history_jump(target.item)
	}
	editor.mouse_revision = txn.doc_revision(target.doc)
	editor.mouse_chord = {}
	log.infof("mouse: reversed %v chord restored the original text and selection", operation)
}

editor_mouse_clipboard_result :: proc(
	id: mouse.Target_ID,
	request_id: platform.Clipboard_Request_ID,
	operation: platform.Clipboard_Operation,
	applied: bool,
	transaction: txn.Transaction_ID,
	data_length: int,
) {
	runtime := &editor.mouse_chord
	if !runtime.active || runtime.target != id || runtime.request_id != u64(request_id) {
		return
	}
	if (runtime.operation == .Cut && operation != .Write) || (runtime.operation == .Paste && operation != .Read) {
		return
	}
	if !applied {
		runtime^ = {}
		return
	}
	runtime.transaction = transaction
	if runtime.operation == .Paste {
		target := editor_text_target_by_id(id)
		if target.selection != nil {
			end := target.selection.active
			start := end - data_length
			if start >= 0 && start <= end && end <= rope.tree_byte_count(&target.doc.tree) {
				target.selection^ = txn.Selection{anchor = start, active = end, affinity = .Left}
			}
		}
	}
	if mouse.active(&editor.mouse_gesture) && editor.mouse_gesture.target == id {
		if target := editor_text_target_by_id(id); target.doc != nil {
			editor.mouse_revision = txn.doc_revision(target.doc)
		}
	}
	log.infof("mouse: chord %v applied transaction=%d", runtime.operation, u64(transaction))
}

editor_look_mouse :: proc(action: mouse.Look) {
	target := editor_text_target_by_id(action.target)
	if target.doc == nil || target.selection == nil {
		return
	}
	range, range_err := mouse.action_range(target.doc, target.selection^, action.anchor, action.active, .Look)
	if !errs.ok(range_err) {
		editor_report(range_err)
		return
	}
	data, read_err := mouse.read_action_text(target.doc, range, context.temp_allocator)
	if !errs.ok(read_err) {
		editor_report(read_err)
		return
	}
	defer delete(data, context.temp_allocator)
	body := editor_target_body(target)
	if body.selection == nil {
		return
	}
	if target.kind == .Body {
		caret := range.end
		if action.reverse {
			caret = range.start
		}
		body.selection^ = txn.Selection{anchor = caret, active = caret, affinity = .Left}
	}
	editor_look_text(target, data, action.reverse)
}

editor_search_body :: proc(body: Mouse_Text_Target, needle: []byte, reverse: bool) {
	if body.doc == nil || body.selection == nil || len(needle) == 0 {
		return
	}
	selection_range := editing.selection_range(body.selection^)
	start := selection_range.end
	if reverse {
		start = selection_range.start
	}
	match, found, err := mouse.find_literal(body.doc, needle, start, reverse)
	if !errs.ok(err) {
		editor_report(err)
		return
	}
	if !found {
		log.infof("mouse: look %q reverse=%v found no match", string(needle), reverse)
		return
	}
	body.selection^ = txn.Selection{anchor = match.start, active = match.end, affinity = .Left}
	log.infof("mouse: look %q reverse=%v match=[%d,%d)", string(needle), reverse, match.start, match.end)
}
