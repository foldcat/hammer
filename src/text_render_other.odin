#+build !linux

package main

import coords "core/coords"
import layout "core/layout"

text_render_setup :: proc() {}
text_render_destroy :: proc() {}
text_render_document :: proc(win: layout.Window, fb: coords.Physical_Size, quads: ^[dynamic]Vertex) {}
text_render_draw :: proc(body: layout.Rect, fb: coords.Physical_Size) {}
