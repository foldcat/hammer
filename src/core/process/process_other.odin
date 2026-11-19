#+build !linux
#+build !windows

package process

import errs "../errs"

Platform_Pipe :: struct {}
Platform_Process :: struct {}

platform_read_pipe :: proc(pipe: ^Pipe, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	return 0, .Closed, errs.new(.Unsupported, "process: pipe I/O is implemented only on Linux and Windows", allocator = allocator)
}

platform_write_pipe :: proc(pipe: ^Pipe, data: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	return 0, .Closed, errs.new(.Unsupported, "process: pipe I/O is implemented only on Linux and Windows", allocator = allocator)
}

platform_spawn :: proc(desc: Description, allocator := context.allocator) -> (Handle, errs.Error) {
	return {}, errs.new(.Unsupported, "process: spawning is implemented only on Linux and Windows", allocator = allocator)
}

platform_try_wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, bool, errs.Error) {
	return {}, false, errs.new(.Unsupported, "process: waiting is implemented only on Linux and Windows", allocator = allocator)
}

platform_request_stop :: proc(handle: ^Handle, force: bool, allocator := context.allocator) -> errs.Error {
	return errs.new(.Unsupported, "process: stopping is implemented only on Linux and Windows", allocator = allocator)
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
