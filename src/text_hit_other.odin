#+build !linux
#+build !windows

package main

import coords "core/coords"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

Text_Hit :: struct {
	offset:   int,
	affinity: txn.Affinity,
}

text_hit_test :: proc(pos: coords.Logical_Point, clamp_to_visible: bool, body: layout.Rect, first_line: rope.Line_Index, doc: ^txn.Doc) -> (Text_Hit, bool) {
	return {}, false
}
