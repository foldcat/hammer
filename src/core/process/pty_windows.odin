package process

import errs "../errs"

Platform_Pty :: struct {}

platform_pty_spawn :: proc(desc: Description, options: Pty_Options, allocator := context.allocator) -> (Pty, errs.Error) {
	return {}, errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}

platform_pty_resize :: proc(pty: ^Pty, size: Winsize, allocator := context.allocator) -> errs.Error {
	return errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}

platform_pty_read :: proc(pty: ^Pty, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	return 0, .Closed, errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}

platform_pty_try_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, bool, errs.Error) {
	return {}, false, errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}

platform_pty_wait :: proc(pty: ^Pty, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	return {}, errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}

platform_pty_stop :: proc(pty: ^Pty, force: bool, allocator := context.allocator) -> errs.Error {
	return errs.new(.Unsupported, "process: ConPTY is not yet implemented on Windows", allocator = allocator)
}
