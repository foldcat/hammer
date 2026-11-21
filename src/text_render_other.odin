#+build !linux
#+build !windows

package main

import config "core/config"
import console "core/console"
import coords "core/coords"
import layout "core/layout"
import rope "core/rope"
import txn "core/txn"

text_render_setup :: proc() {}
text_render_destroy :: proc() {}
text_render_begin :: proc() {}
text_render_document :: proc(win: layout.Window, gutter: layout.Rect, line_numbers: bool, doc: ^txn.Doc, selection: txn.Selection, first_line: rope.Line_Index, first_row: int, active: bool, line_height_override: f32, wrap_mode: config.Wrap_Mode, horizontal_offset: ^f32, styles: []console.Style_Run, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {}
text_render_draw :: proc(fb: coords.Physical_Size) {}
