package main

import "core:log"
import "core:math"

import coords "core/coords"
import input "core/input"
import layout "core/layout"
import rope "core/rope"
import scroll "core/scroll"
import txn "core/txn"
import view "core/view"

MAX_SCROLL_ROWS_PER_EVENT :: 64
WHEEL_ROWS_PER_NOTCH :: f32(3)

editor_normalize_view_origin :: proc(item: ^view.View, doc: ^txn.Doc, body: layout.Rect) -> int {
	if item == nil || doc == nil {
		return 1
	}
	line_count := rope_line_count(doc)
	view.clamp_origin(item, line_count)
	rows, ok := text_visual_row_count(doc, item.first_line, body, item.wrap_mode)
	if !ok {
		item.first_row = 0
		return 1
	}
	item.first_row = clamp(item.first_row, 0, max(0, rows - 1))
	return max(1, rows)
}

rope_line_count :: proc(doc: ^txn.Doc) -> int {
	if doc == nil {
		return 1
	}
	return rope.tree_line_count(&doc.tree)
}

editor_visible_rows :: proc(body: layout.Rect) -> int {
	line_height := coords.points_to_logical_px(state.dpi.points) * cfg.Line_Height
	if line_height <= 0 || body.height <= 0 {
		return 1
	}
	return max(1, int(body.height / line_height))
}

editor_scroll_visual_rows :: proc(item: ^view.View, doc: ^txn.Doc, body: layout.Rect, delta: int) {
	if item == nil || doc == nil {
		return
	}
	editor_normalize_view_origin(item, doc, body)
	bounded_delta := clamp(delta, -MAX_SCROLL_ROWS_PER_EVENT, MAX_SCROLL_ROWS_PER_EVENT)
	line_count := rope_line_count(doc)
	for _ in 0 ..< abs(bounded_delta) {
		if bounded_delta > 0 {
			rows, ok := text_visual_row_count(doc, item.first_line, body, item.wrap_mode)
			if !ok {
				return
			}
			if item.first_row + 1 < rows {
				item.first_row += 1
			} else if int(item.first_line) + 1 < line_count {
				item.first_line += 1
				item.first_row = 0
			} else {
				return
			}
		} else if bounded_delta < 0 {
			if item.first_row > 0 {
				item.first_row -= 1
			} else if item.first_line > 0 {
				item.first_line -= 1
				rows, ok := text_visual_row_count(doc, item.first_line, body, item.wrap_mode)
				if !ok {
					item.first_line += 1
					return
				}
				item.first_row = max(0, rows - 1)
			} else {
				return
			}
		}
	}
}

editor_wheel_vertical :: proc(item: ^view.View, doc: ^txn.Doc, body: layout.Rect, delta: f32) {
	if item == nil || doc == nil || delta == 0 || math.is_nan(delta) || math.is_inf(delta) {
		return
	}
	item.wheel_remainder += clamp(delta, -MAX_SCROLL_ROWS_PER_EVENT, MAX_SCROLL_ROWS_PER_EVENT) * WHEEL_ROWS_PER_NOTCH
	steps := int(item.wheel_remainder)
	item.wheel_remainder -= f32(steps)
	steps = clamp(steps, -MAX_SCROLL_ROWS_PER_EVENT, MAX_SCROLL_ROWS_PER_EVENT)
	previous_line, previous_row := item.first_line, item.first_row
	editor_scroll_visual_rows(item, doc, body, steps)
	if item.first_line != previous_line || item.first_row != previous_row {
		log.infof("view: vertical scroll window=%d line=%d row=%d", u64(item.window_id), int(item.first_line), item.first_row)
	}
}

editor_scrollbar_pointer_down :: proc(event: input.Pointer_Down, area: layout.Hit, body: layout.Rect) -> bool {
	track, text := scroll.body_rects(body)
	was_active := scroll.active(&editor.scrollbar)
	if !was_active && (area.kind != .Body || !layout.contains(track, event.pos)) {
		return false
	}
	editor_cancel_pointer_gesture()
	editor_cancel_close_review()
	if was_active {
		return true
	}
	on_thumb := false
	if item, found := view.find(&editor.views, area.window_id); found {
		doc := &editor_buffer_for_view(item).doc
		first_line_rows := editor_normalize_view_origin(item, doc, text)
		thumb := scroll.thumb_rect(track, int(item.first_line), item.first_row, first_line_rows, rope_line_count(doc), editor_visible_rows(text))
		on_thumb = layout.contains(thumb, event.pos)
	}
	action := scroll.down(&editor.scrollbar, area.window_id, event.button, event.pos, track, mouse_now_ms(), on_thumb)
	editor_dispatch_scrollbar_action(action)
	return true
}

editor_scrollbar_pointer_move :: proc(event: input.Pointer_Move) -> bool {
	if !scroll.active(&editor.scrollbar) {
		return false
	}
	editor_dispatch_scrollbar_action(scroll.move(&editor.scrollbar, event.pos, event.buttons))
	return true
}

editor_scrollbar_pointer_up :: proc(event: input.Pointer_Up) -> bool {
	if !scroll.active(&editor.scrollbar) {
		return false
	}
	scroll.up(&editor.scrollbar, event.button)
	return true
}

editor_poll_scrollbar :: proc() {
	editor_dispatch_scrollbar_action(scroll.repeat(&editor.scrollbar, mouse_now_ms()))
}

editor_dispatch_scrollbar_action :: proc(action: scroll.Action) {
	if action.window_id == 0 {
		return
	}
	item, found := view.find(&editor.views, action.window_id)
	if !found {
		scroll.cancel(&editor.scrollbar)
		return
	}
	doc := &editor_buffer_for_view(item).doc
	geometry, _, ok := current_layout()
	if !ok {
		scroll.cancel(&editor.scrollbar)
		return
	}
	win, win_found := window_for_id(&geometry, action.window_id)
	if !win_found {
		scroll.cancel(&editor.scrollbar)
		return
	}
	_, text := scroll.body_rects(win.body)
	previous_line, previous_row := item.first_line, item.first_row
	kind := "relative"
	switch action.kind {
	case .Relative:
		editor_scroll_visual_rows(item, doc, text, action.delta)
	case .Absolute:
		kind = "absolute"
		item.first_line = rope.Line_Index(scroll.absolute_line(action.fraction, rope_line_count(doc)))
		item.first_row = 0
		item.wheel_remainder = 0
	}
	if item.first_line != previous_line || item.first_row != previous_row {
		log.infof("view: scrollbar %s window=%d line=%d row=%d", kind, u64(item.window_id), int(item.first_line), item.first_row)
	}
}
