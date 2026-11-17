#+build !linux
#+build !windows

package fonts

import errs "../../core/errs"

Impl :: struct {}

init :: proc(set: ^Set, options: Options, allocator := context.allocator) -> errs.Error {
	return errs.new(.Unsupported, "font discovery is currently implemented only on Linux and Windows", allocator = allocator)
}

destroy :: proc(set: ^Set) {
	set^ = Set{}
}

ensure_fallback :: proc(set: ^Set, codepoint: rune) -> (^Face, errs.Error) {
	return nil, errs.new(.Unsupported, "font fallback is currently implemented only on Linux and Windows", allocator = context.allocator)
}
