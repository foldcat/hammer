#+build !linux
#+build !windows

package main

import coords "core/coords"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

text_render_setup :: proc() {}
text_render_destroy :: proc() {}
text_render_begin :: proc() {}
text_render_document :: proc(win: layout.Window, doc: ^txn.Doc, selection: txn.Selection, first_line: rope.Line_Index, active: bool, line_height_override: f32, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {}
text_render_draw :: proc(fb: coords.Physical_Size) {}
