package process_test

import win32 "core:sys/windows"
import "core:testing"

import process "hammer:core/process"

write_all :: proc(t: ^testing.T, pipe: ^process.Pipe, data: []byte) {
	native, open := process.pipe_handle(pipe)
	if !open {
		testing.expect(t, false, "pipe is closed")
		return
	}
	remaining := data
	for len(remaining) > 0 {
		written: win32.DWORD
		if !win32.WriteFile(win32.HANDLE(native), raw_data(remaining), win32.DWORD(len(remaining)), &written, nil) || written == 0 {
			testing.expect(t, false, "pipe write failed")
			return
		}
		remaining = remaining[int(written):]
	}
}

read_some :: proc(pipe: ^process.Pipe, buffer: []byte) -> (int, bool) {
	native, open := process.pipe_handle(pipe)
	if !open {
		return 0, false
	}
	count: win32.DWORD
	if win32.ReadFile(win32.HANDLE(native), raw_data(buffer), win32.DWORD(len(buffer)), &count, nil) {
		return int(count), true
	}
	if win32.GetLastError() == win32.ERROR_BROKEN_PIPE {
		return 0, true
	}
	return 0, false
}
