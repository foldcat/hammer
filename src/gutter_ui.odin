package main

import "core:math"

import layout "core/layout"
import scroll "core/scroll"
import txn "core/txn"
import view "core/view"

GUTTER_PADDING :: f32(4)
GUTTER_GAP :: f32(4)

editor_line_number_width :: proc(item: ^view.View, doc: ^txn.Doc) -> f32 {
	if item == nil || doc == nil || !item.line_numbers {
		return 0
	}
	digit_advance := text_measure_advance("0")
	if digit_advance <= 0 || math.is_nan(digit_advance) || math.is_inf(digit_advance) {
		return 0
	}
	return f32(view.line_number_digits(rope_line_count(doc))) * digit_advance + 2 * GUTTER_PADDING + GUTTER_GAP
}

editor_body_parts :: proc(item: ^view.View, doc: ^txn.Doc, body: layout.Rect) -> (track, gutter, text: layout.Rect) {
	track, text = scroll.body_rects(body)
	gutter = text
	gutter.width = min(max(0, editor_line_number_width(item, doc)), text.width)
	text.x += gutter.width
	text.width = max(0, text.width - gutter.width)
	return track, gutter, text
}
