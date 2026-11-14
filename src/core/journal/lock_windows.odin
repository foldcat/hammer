package journal

import "core:os"
import win32 "core:sys/windows"

platform_lock_file :: proc(file: ^os.File) -> (bool, os.Error) {
	overlapped: win32.OVERLAPPED
	flags := win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY
	if win32.LockFileEx(win32.HANDLE(os.fd(file)), flags, 0, 1, 0, &overlapped) {
		return true, nil
	}
	err := win32.GetLastError()
	if err == win32.ERROR_LOCK_VIOLATION || err == win32.ERROR_LOCK_FAILED {
		return false, nil
	}
	return false, os.Platform_Error(err)
}

platform_unlock_file :: proc(file: ^os.File) -> os.Error {
	overlapped: win32.OVERLAPPED
	if win32.UnlockFileEx(win32.HANDLE(os.fd(file)), 0, 1, 0, &overlapped) {
		return nil
	}
	return os.Platform_Error(win32.GetLastError())
}
