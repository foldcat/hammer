#+build !linux
#+build !windows

package process

import errs "../errs"

Platform_Pipe :: struct {}

platform_read_pipe :: proc(pipe: ^Pipe, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	return 0, .Closed, errs.new(.Unsupported, "process: pipe I/O is implemented only on Linux and Windows", allocator = allocator)
}

platform_write_pipe :: proc(pipe: ^Pipe, data: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	return 0, .Closed, errs.new(.Unsupported, "process: pipe I/O is implemented only on Linux and Windows", allocator = allocator)
}

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
