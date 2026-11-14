package filesave

import "base:runtime"
import "core:os"

import errs "../errs"
import fileload "../fileload"

// Operation_Hooks is an optional OS adapter/failure-injection boundary. Nil
// fields use the real operation. `data` is passed through unchanged and is never
// retained after save_tree returns. Hooks must preserve the real operation's
// success, ownership, and handle-cleanup contracts.
Operation_Hooks :: struct {
	data:        rawptr,
	create_temp: proc(data: rawptr, dir, pattern: string) -> (^os.File, os.Error),
	write:       proc(data: rawptr, file: ^os.File, bytes: []byte) -> (int, os.Error),
	sync:        proc(data: rawptr, file: ^os.File) -> os.Error,
	chmod:       proc(data: rawptr, file: ^os.File, mode: os.Permissions) -> os.Error,
	close:       proc(data: rawptr, file: ^os.File) -> os.Error,
	remove:      proc(data: rawptr, path: string) -> os.Error,
	link:        proc(data: rawptr, old_path, new_path: string) -> os.Error,
	rename:      proc(data: rawptr, old_path, new_path: string) -> os.Error,
	capture:     proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (fileload.Capture, errs.Error),
}

operation_create_temp :: proc(hooks: ^Operation_Hooks, dir, pattern: string) -> (^os.File, os.Error) {
	if hooks != nil && hooks.create_temp != nil {
		return hooks.create_temp(hooks.data, dir, pattern)
	}
	return os.create_temp_file(dir, pattern)
}

operation_write :: proc(hooks: ^Operation_Hooks, file: ^os.File, bytes: []byte) -> (int, os.Error) {
	if hooks != nil && hooks.write != nil {
		return hooks.write(hooks.data, file, bytes)
	}
	return os.write(file, bytes)
}

operation_sync :: proc(hooks: ^Operation_Hooks, file: ^os.File) -> os.Error {
	if hooks != nil && hooks.sync != nil {
		return hooks.sync(hooks.data, file)
	}
	return os.sync(file)
}

operation_chmod :: proc(hooks: ^Operation_Hooks, file: ^os.File, mode: os.Permissions) -> os.Error {
	if hooks != nil && hooks.chmod != nil {
		return hooks.chmod(hooks.data, file, mode)
	}
	return os.fchmod(file, mode)
}

operation_close :: proc(hooks: ^Operation_Hooks, file: ^os.File) -> os.Error {
	if hooks != nil && hooks.close != nil {
		return hooks.close(hooks.data, file)
	}
	return os.close(file)
}

operation_remove :: proc(hooks: ^Operation_Hooks, path: string) -> os.Error {
	if hooks != nil && hooks.remove != nil {
		return hooks.remove(hooks.data, path)
	}
	return os.remove(path)
}

operation_link :: proc(hooks: ^Operation_Hooks, old_path, new_path: string) -> os.Error {
	if hooks != nil && hooks.link != nil {
		return hooks.link(hooks.data, old_path, new_path)
	}
	return os.link(old_path, new_path)
}

operation_rename :: proc(hooks: ^Operation_Hooks, old_path, new_path: string) -> os.Error {
	if hooks != nil && hooks.rename != nil {
		return hooks.rename(hooks.data, old_path, new_path)
	}
	return os.rename(old_path, new_path)
}

operation_capture :: proc(
	hooks: ^Operation_Hooks,
	path: string,
	allocator: runtime.Allocator,
) -> (fileload.Capture, errs.Error) {
	if hooks != nil && hooks.capture != nil {
		return hooks.capture(hooks.data, path, allocator)
	}
	return fileload.capture_file(path, allocator)
}
