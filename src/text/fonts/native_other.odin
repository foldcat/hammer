#+build !linux

package fonts

import errs "../../core/errs"

Impl :: struct {}

init :: proc(set: ^Set, options: Options, allocator := context.allocator) -> errs.Error {
	return errs.new(.Unsupported, "font discovery is currently implemented only on Linux", allocator = allocator)
}

destroy :: proc(set: ^Set) {
	set^ = Set{}
}
