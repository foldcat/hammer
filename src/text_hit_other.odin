#+build !linux
#+build !windows

package main

import config "core/config"
import coords "core/coords"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

Text_Hit :: struct {
	offset:   int,
	affinity: txn.Affinity,
}

text_hit_test :: proc(pos: coords.Logical_Point, clamp_to_visible: bool, body: layout.Rect, first_line: rope.Line_Index, first_row: int, wrap_mode: config.Wrap_Mode, horizontal_offset: ^f32, doc: ^txn.Doc) -> (Text_Hit, bool) {
	return {}, false
}
