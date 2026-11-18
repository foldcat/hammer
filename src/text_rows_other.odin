#+build !linux
#+build !windows

package main

import config "core/config"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

text_visual_row_count :: proc(doc: ^txn.Doc, line_index: rope.Line_Index, body: layout.Rect, wrap_mode: config.Wrap_Mode) -> (int, bool) {
	return 1, true
}
