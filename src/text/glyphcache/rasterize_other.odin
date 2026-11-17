#+build !linux
#+build !windows

package glyphcache

import errs "../../core/errs"

native_rasterize :: proc(user: rawptr, key: Key, allocator := context.allocator) -> (Rasterized, errs.Error) {
	return {}, errs.new(.Unsupported, "native glyph rasterization currently requires Linux or Windows", allocator = allocator)
}

native_char_index :: proc(face: rawptr, codepoint: rune, allocator := context.allocator) -> (u32, errs.Error) {
	return 0, errs.new(.Unsupported, "native glyph lookup currently requires Linux or Windows", allocator = allocator)
}
