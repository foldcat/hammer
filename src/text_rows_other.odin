#+build !linux
#+build !windows

package main

import config "core/config"
import coords "core/coords"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

text_visual_row_count :: proc(doc: ^txn.Doc, line_index: rope.Line_Index, body: layout.Rect, wrap_mode: config.Wrap_Mode) -> (int, bool) {
	return 1, true
}

text_caret_x :: proc(doc: ^txn.Doc, selection: txn.Selection, body: layout.Rect) -> (f32, bool) {
	return 0, false
}

text_measure_advance :: proc(text: string) -> f32 {
	return coords.points_to_logical_px(state.dpi.points) * 0.6
}
