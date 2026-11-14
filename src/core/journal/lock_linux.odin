package journal

import "core:os"
import "core:sys/linux"

platform_lock_file :: proc(file: ^os.File) -> (bool, os.Error) {
	errno := linux.flock(linux.Fd(os.fd(file)), {.EX, .NB})
	if errno == .NONE {
		return true, nil
	}
	if errno == .EAGAIN {
		return false, nil
	}
	return false, os.Platform_Error(errno)
}

platform_unlock_file :: proc(file: ^os.File) -> os.Error {
	errno := linux.flock(linux.Fd(os.fd(file)), {.UN})
	if errno == .NONE {
		return nil
	}
	return os.Platform_Error(errno)
}
