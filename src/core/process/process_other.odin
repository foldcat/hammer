#+build !linux
#+build !windows

package process

import errs "../errs"

platform_spawn :: proc(desc: Description, allocator := context.allocator) -> (Handle, errs.Error) {
	return {}, errs.new(.Unsupported, "process: spawning is implemented only on Linux and Windows", allocator = allocator)
}

platform_wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	return {}, errs.new(.Unsupported, "process: waiting is implemented only on Linux and Windows", allocator = allocator)
}

close_pipe :: proc(pipe: ^Pipe, allocator := context.allocator) -> errs.Error {
	if pipe != nil {
		pipe^ = {}
	}
	return {}
}
