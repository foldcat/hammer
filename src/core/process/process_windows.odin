package process

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/windows"
import mem_virtual "core:mem/virtual"

import errs "../errs"

foreign import kernel32 "system:Kernel32.lib"

PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002
ERROR_IO_INCOMPLETE :: windows.DWORD(996)
PIPE_BUFFER_BYTES :: 64 * 1024

Platform_Pipe :: struct {
	overlapped: windows.OVERLAPPED,
	pending:    bool,
}

next_pipe_id: u64

STARTUPINFOEXW :: struct {
	startup:        windows.STARTUPINFOW,
	attribute_list: rawptr,
}

@(default_calling_convention="system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: rawptr,
		dwAttributeCount: windows.DWORD,
		dwFlags: windows.DWORD,
		lpSize: ^windows.SIZE_T,
	) -> windows.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr,
		dwFlags: windows.DWORD,
		Attribute: windows.DWORD_PTR,
		lpValue: rawptr,
		cbSize: windows.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize: ^windows.SIZE_T,
	) -> windows.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

Windows_Pipes :: struct {
	stdin_read:   windows.HANDLE,
	stdin_write:  windows.HANDLE,
	stdout_read:  windows.HANDLE,
	stdout_write: windows.HANDLE,
	stderr_read:  windows.HANDLE,
	stderr_write: windows.HANDLE,
}

close_raw :: proc(handle: ^windows.HANDLE) {
	if handle^ == nil {
		return
	}
	windows.CloseHandle(handle^)
	handle^ = nil
}

close_all :: proc(pipes: ^Windows_Pipes) {
	handles := []^windows.HANDLE{
		&pipes.stdin_read,
		&pipes.stdin_write,
		&pipes.stdout_read,
		&pipes.stdout_write,
		&pipes.stderr_read,
		&pipes.stderr_write,
	}
	for handle in handles {
		close_raw(handle)
	}
}

open_pipe :: proc(parent_reads: bool, allocator := context.allocator) -> (read_end, write_end: windows.HANDLE, errno: windows.DWORD) {
	pipe_id := sync.atomic_add(&next_pipe_id, 1)
	name := fmt.aprintf(`\\.\pipe\hammer-process-%d-%d`, windows.GetCurrentProcessId(), pipe_id, allocator = allocator)
	if name == "" {
		return nil, nil, windows.ERROR_NOT_ENOUGH_MEMORY
	}
	name_wide := windows.utf8_to_wstring(name, allocator)
	if name_wide == nil {
		return nil, nil, windows.ERROR_NOT_ENOUGH_MEMORY
	}

	direction := windows.PIPE_ACCESS_OUTBOUND
	child_access := windows.GENERIC_READ
	if parent_reads {
		direction = windows.PIPE_ACCESS_INBOUND
		child_access = windows.GENERIC_WRITE
	}
	parent := windows.CreateNamedPipeW(
		name_wide,
		direction | windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE | windows.PIPE_REJECT_REMOTE_CLIENTS,
		1,
		PIPE_BUFFER_BYTES,
		PIPE_BUFFER_BYTES,
		0,
		nil,
	)
	if parent == windows.INVALID_HANDLE {
		return nil, nil, windows.GetLastError()
	}
	attributes := windows.SECURITY_ATTRIBUTES{
		nLength = size_of(windows.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	child := windows.CreateFileW(
		name_wide,
		child_access,
		0,
		&attributes,
		windows.OPEN_EXISTING,
		0,
		nil,
	)
	if child == windows.INVALID_HANDLE {
		errno = windows.GetLastError()
		windows.CloseHandle(parent)
		return nil, nil, errno
	}
	if !windows.ConnectNamedPipe(parent, nil) {
		connect_errno := windows.GetLastError()
		if connect_errno != windows.ERROR_PIPE_CONNECTED {
			windows.CloseHandle(parent)
			windows.CloseHandle(child)
			return nil, nil, connect_errno
		}
	}
	if !windows.SetHandleInformation(parent, windows.HANDLE_FLAG_INHERIT, 0) {
		errno = windows.GetLastError()
		windows.CloseHandle(parent)
		windows.CloseHandle(child)
		return nil, nil, errno
	}
	if parent_reads {
		return parent, child, 0
	}
	return child, parent, 0
}

open_all :: proc(pipes: ^Windows_Pipes, allocator := context.allocator) -> windows.DWORD {
	pipes^ = {}
	errno := windows.DWORD(0)
	pipes.stdin_read, pipes.stdin_write, errno = open_pipe(false, allocator)
	if errno != 0 {
		return errno
	}
	pipes.stdout_read, pipes.stdout_write, errno = open_pipe(true, allocator)
	if errno != 0 {
		return errno
	}
	pipes.stderr_read, pipes.stderr_write, errno = open_pipe(true, allocator)
	return errno
}

windows_error :: proc(action: string, errno: windows.DWORD, allocator := context.allocator) -> errs.Error {
	kind := errs.Kind.IO
	if errno == windows.ERROR_FILE_NOT_FOUND || errno == windows.ERROR_PATH_NOT_FOUND {
		kind = .NotFound
	} else if errno == windows.ERROR_NOT_ENOUGH_MEMORY || errno == windows.ERROR_OUTOFMEMORY {
		kind = .Resource_Limit
	}
	return errs.newf(kind, "process: %s failed: Windows error %d", action, errno, allocator = allocator)
}

append_quoted_argument :: proc(builder: ^strings.Builder, argument: string) {
	strings.write_byte(builder, '"')
	index := 0
	for index < len(argument) {
		backslashes := 0
		for index < len(argument) && argument[index] == '\\' {
			backslashes += 1
			index += 1
		}
		if index == len(argument) {
			for _ in 0 ..< backslashes * 2 {
				strings.write_byte(builder, '\\')
			}
			break
		}
		if argument[index] == '"' {
			for _ in 0 ..< backslashes * 2 + 1 {
				strings.write_byte(builder, '\\')
			}
			strings.write_byte(builder, '"')
			index += 1
			continue
		}
		for _ in 0 ..< backslashes {
			strings.write_byte(builder, '\\')
		}
		strings.write_byte(builder, argument[index])
		index += 1
	}
	strings.write_byte(builder, '"')
}

build_command_line :: proc(command: []string, allocator := context.allocator) -> (string, bool) {
	builder, err := strings.builder_make(allocator)
	if err != nil {
		return "", false
	}
	for argument, index in command {
		if index > 0 {
			strings.write_byte(&builder, ' ')
		}
		append_quoted_argument(&builder, argument)
	}
	return strings.to_string(builder), true
}

build_environment :: proc(environment: []string, allocator := context.allocator) -> ([]u16, bool) {
	units, err := make([dynamic]u16, 0, len(environment) + 2, allocator)
	if err != nil {
		return nil, false
	}
	if len(environment) == 0 {
		append(&units, 0)
	}
	for entry in environment {
		converted := windows.utf8_to_utf16(entry, allocator)
		if len(converted) == 0 {
			return nil, false
		}
		append(&units, ..converted)
		append(&units, 0)
	}
	append(&units, 0)
	return units[:], true
}

platform_spawn :: proc(desc: Description, allocator := context.allocator) -> (Handle, errs.Error) {
	arena: mem_virtual.Arena
	if arena_err := mem_virtual.arena_init_growing(&arena); arena_err != .None {
		return {}, errs.newf(.Resource_Limit, "process: cannot initialize spawn arena: %v", arena_err, allocator = allocator)
	}
	defer {
		mem_virtual.arena_free_all(&arena)
		mem_virtual.arena_destroy(&arena)
	}
	scratch := mem_virtual.arena_allocator(&arena)

	command_line, command_ok := build_command_line(desc.command, scratch)
	if !command_ok {
		return {}, errs.new(.Resource_Limit, "process: cannot allocate quoted command line", allocator = allocator)
	}
	command_line_wide := windows.utf8_to_wstring(command_line, scratch)
	if command_line_wide == nil {
		return {}, errs.new(.Invalid_Input, "process: command line is not valid UTF-8 or could not be allocated", allocator = allocator)
	}
	working_dir_wide: windows.wstring
	if desc.working_dir != "" {
		working_dir_wide = windows.utf8_to_wstring(desc.working_dir, scratch)
		if working_dir_wide == nil {
			return {}, errs.new(.Invalid_Input, "process: working directory is not valid UTF-8 or could not be allocated", allocator = allocator)
		}
	}

	environment_block: rawptr
	if desc.environment != nil {
		environment, environment_ok := build_environment(desc.environment, scratch)
		if !environment_ok {
			return {}, errs.new(.Invalid_Input, "process: environment is not valid UTF-8 or could not be allocated", allocator = allocator)
		}
		environment_block = raw_data(environment)
	}

	pipes: Windows_Pipes
	if errno := open_all(&pipes, scratch); errno != 0 {
		close_all(&pipes)
		return {}, windows_error("pipe creation", errno, allocator)
	}
	defer close_all(&pipes)

	attribute_size: windows.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attribute_size)
	if attribute_size == 0 {
		return {}, windows_error("attribute-list sizing", windows.GetLastError(), allocator)
	}
	attribute_words := (int(attribute_size) + size_of(windows.DWORD_PTR) - 1) / size_of(windows.DWORD_PTR)
	attribute_storage, attribute_err := make([]windows.DWORD_PTR, attribute_words, scratch)
	if attribute_err != nil {
		return {}, errs.new(.Resource_Limit, "process: cannot allocate handle-inheritance list", allocator = allocator)
	}
	attribute_list := rawptr(raw_data(attribute_storage))
	if !InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size) {
		return {}, windows_error("attribute-list initialization", windows.GetLastError(), allocator)
	}
	defer DeleteProcThreadAttributeList(attribute_list)

	inherited := []windows.HANDLE{pipes.stdin_read, pipes.stdout_write, pipes.stderr_write}
	if !UpdateProcThreadAttribute(
		attribute_list,
		0,
		PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		raw_data(inherited),
		size_of(windows.HANDLE) * len(inherited),
		nil,
		nil,
	) {
		return {}, windows_error("handle-inheritance setup", windows.GetLastError(), allocator)
	}

	startup := STARTUPINFOEXW{
		startup = {
			cb = size_of(STARTUPINFOEXW),
			dwFlags = windows.STARTF_USESTDHANDLES,
			hStdInput = pipes.stdin_read,
			hStdOutput = pipes.stdout_write,
			hStdError = pipes.stderr_write,
		},
		attribute_list = attribute_list,
	}
	process_info: windows.PROCESS_INFORMATION
	created := windows.CreateProcessW(
		nil,
		command_line_wide,
		nil,
		nil,
		true,
		windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_NEW_PROCESS_GROUP |
			windows.CREATE_NO_WINDOW | windows.EXTENDED_STARTUPINFO_PRESENT,
		environment_block,
		working_dir_wide,
		(^windows.STARTUPINFOW)(&startup),
		&process_info,
	)
	if !created {
		return {}, windows_error("CreateProcessW", windows.GetLastError(), allocator)
	}
	close_raw(&pipes.stdin_read)
	close_raw(&pipes.stdout_write)
	close_raw(&pipes.stderr_write)
	if !windows.CloseHandle(process_info.hThread) {
		errno := windows.GetLastError()
		windows.TerminateProcess(process_info.hProcess, 1)
		windows.WaitForSingleObject(process_info.hProcess, windows.INFINITE)
		windows.CloseHandle(process_info.hProcess)
		return {}, windows_error("initial-thread cleanup", errno, allocator)
	}

	handle := Handle{
		id = Process_ID(process_info.dwProcessId),
		process = uintptr(process_info.hProcess),
		stdin = {native = uintptr(pipes.stdin_write), open = true},
		stdout = {native = uintptr(pipes.stdout_read), open = true},
		stderr = {native = uintptr(pipes.stderr_read), open = true},
	}
	pipes.stdin_write = nil
	pipes.stdout_read = nil
	pipes.stderr_read = nil
	return handle, {}
}

platform_wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	process_handle := windows.HANDLE(handle.process)
	if result := windows.WaitForSingleObject(process_handle, windows.INFINITE); result != windows.WAIT_OBJECT_0 {
		return {}, windows_error("WaitForSingleObject", windows.GetLastError(), allocator)
	}
	exit_code: windows.DWORD
	got_exit_code := windows.GetExitCodeProcess(process_handle, &exit_code)
	exit_error := windows.GetLastError() if !got_exit_code else 0
	close_error := windows.DWORD(0)
	if !windows.CloseHandle(process_handle) {
		close_error = windows.GetLastError()
	}
	handle.process = 0
	if !got_exit_code {
		return {}, windows_error("GetExitCodeProcess", exit_error, allocator)
	}
	if close_error != 0 {
		return {}, windows_error("process-handle cleanup", close_error, allocator)
	}
	return Exit_Status{code = int(exit_code), success = exit_code == 0}, {}
}

prepare_overlapped :: proc(pipe: ^Pipe, allocator := context.allocator) -> errs.Error {
	if pipe.platform.overlapped.hEvent == nil {
		event := windows.CreateEventW(nil, false, false, nil)
		if event == nil {
			return windows_error("pipe-event creation", windows.GetLastError(), allocator)
		}
		pipe.platform.overlapped.hEvent = event
	}
	if !windows.ResetEvent(pipe.platform.overlapped.hEvent) {
		return windows_error("pipe-event reset", windows.GetLastError(), allocator)
	}
	pipe.platform.overlapped.Internal = nil
	pipe.platform.overlapped.InternalHigh = nil
	pipe.platform.overlapped.OffsetFull = 0
	return {}
}

complete_overlapped :: proc(pipe: ^Pipe, action: string, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	transferred: windows.DWORD
	if windows.GetOverlappedResult(windows.HANDLE(pipe.native), &pipe.platform.overlapped, &transferred, false) {
		pipe.platform.pending = false
		if transferred == 0 {
			return 0, .End, {}
		}
		return int(transferred), .Data, {}
	}
	errno := windows.GetLastError()
	if errno == windows.ERROR_IO_PENDING || errno == ERROR_IO_INCOMPLETE {
		return 0, .Would_Block, {}
	}
	pipe.platform.pending = false
	if errno == windows.ERROR_BROKEN_PIPE || errno == windows.ERROR_NO_DATA {
		return 0, .End, {}
	}
	if errno == windows.ERROR_OPERATION_ABORTED {
		return 0, .Closed, {}
	}
	return 0, .Closed, windows_error(action, errno, allocator)
}

platform_read_pipe :: proc(pipe: ^Pipe, buffer: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	if len(buffer) > int(max(windows.DWORD)) {
		return 0, .Closed, errs.new(.Resource_Limit, "process: read buffer exceeds Windows I/O limits", allocator = allocator)
	}
	if pipe.platform.pending {
		return complete_overlapped(pipe, "overlapped read", allocator)
	}
	if err := prepare_overlapped(pipe, allocator); !errs.ok(err) {
		return 0, .Closed, err
	}
	transferred: windows.DWORD
	if windows.ReadFile(windows.HANDLE(pipe.native), raw_data(buffer), windows.DWORD(len(buffer)), &transferred, &pipe.platform.overlapped) {
		if transferred == 0 {
			return 0, .End, {}
		}
		return int(transferred), .Data, {}
	}
	errno := windows.GetLastError()
	if errno == windows.ERROR_IO_PENDING {
		pipe.platform.pending = true
		return 0, .Would_Block, {}
	}
	if errno == windows.ERROR_BROKEN_PIPE || errno == windows.ERROR_NO_DATA {
		return 0, .End, {}
	}
	return 0, .Closed, windows_error("read", errno, allocator)
}

platform_write_pipe :: proc(pipe: ^Pipe, data: []byte, allocator := context.allocator) -> (int, IO_Status, errs.Error) {
	if len(data) > int(max(windows.DWORD)) {
		return 0, .Closed, errs.new(.Resource_Limit, "process: write buffer exceeds Windows I/O limits", allocator = allocator)
	}
	if pipe.platform.pending {
		return complete_overlapped(pipe, "overlapped write", allocator)
	}
	if err := prepare_overlapped(pipe, allocator); !errs.ok(err) {
		return 0, .Closed, err
	}
	transferred: windows.DWORD
	if windows.WriteFile(windows.HANDLE(pipe.native), raw_data(data), windows.DWORD(len(data)), &transferred, &pipe.platform.overlapped) {
		if transferred == 0 {
			return 0, .Closed, errs.new(.IO, "process: write made no progress", allocator = allocator)
		}
		return int(transferred), .Data, {}
	}
	errno := windows.GetLastError()
	if errno == windows.ERROR_IO_PENDING {
		pipe.platform.pending = true
		return 0, .Would_Block, {}
	}
	if errno == windows.ERROR_BROKEN_PIPE || errno == windows.ERROR_NO_DATA {
		return 0, .End, {}
	}
	return 0, .Closed, windows_error("write", errno, allocator)
}

close_pipe :: proc(pipe: ^Pipe, allocator := context.allocator) -> errs.Error {
	if pipe == nil || !pipe.open {
		return {}
	}
	native := windows.HANDLE(pipe.native)
	first_errno := windows.DWORD(0)
	if pipe.platform.pending {
		if !windows.CancelIoEx(native, &pipe.platform.overlapped) {
			errno := windows.GetLastError()
			if errno != windows.ERROR_NOT_FOUND {
				first_errno = errno
			}
		}
		transferred: windows.DWORD
		if !windows.GetOverlappedResult(native, &pipe.platform.overlapped, &transferred, true) {
			errno := windows.GetLastError()
			if first_errno == 0 && errno != windows.ERROR_OPERATION_ABORTED &&
				errno != windows.ERROR_BROKEN_PIPE && errno != windows.ERROR_NO_DATA {
				first_errno = errno
			}
		}
		pipe.platform.pending = false
	}
	event := pipe.platform.overlapped.hEvent
	pipe^ = {}
	if !windows.CloseHandle(native) && first_errno == 0 {
		first_errno = windows.GetLastError()
	}
	if event != nil && !windows.CloseHandle(event) && first_errno == 0 {
		first_errno = windows.GetLastError()
	}
	if first_errno != 0 {
		return windows_error("pipe cleanup", first_errno, allocator)
	}
	return {}
}
