package process

import "core:strings"

import errs "../errs"

MAX_ARGUMENTS :: 1024
MAX_ENVIRONMENT_ENTRIES :: 4096
MAX_SPAWN_BYTES :: 1024 * 1024

Process_ID :: distinct u64

// Description borrows all strings for the duration of spawn. command[0] is
// the executable and the remaining elements are distinct arguments; no shell
// parsing or executable-format fallback is performed. A nil environment
// inherits the parent environment, while a non-nil environment is the exact
// KEY=VALUE list passed to the child.
Description :: struct {
	command:     []string,
	working_dir: string,
	environment: []string,
}

// Pipe is an owned parent-side pipe endpoint. Use pipe_handle for platform
// I/O, and close_pipe or Handle.destroy for cleanup; never close the native
// handle separately. The open flag distinguishes a valid zero descriptor.
Pipe :: struct {
	native: uintptr,
	open:   bool,
}

// Handle has unique ownership and must not be copied after a successful
// spawn. The caller owns all three parent-side pipe endpoints and the native
// process handle. Call wait to reap the child before destroy. Pipes may be
// closed independently as their directions finish.
Handle :: struct {
	id:      Process_ID,
	process: uintptr,
	stdin:   Pipe,
	stdout:  Pipe,
	stderr:  Pipe,
}

Exit_Status :: struct {
	code:    int,
	signal:  int,
	success: bool,
}

pipe_handle :: proc(pipe: ^Pipe) -> (uintptr, bool) {
	if pipe == nil || !pipe.open {
		return 0, false
	}
	return pipe.native, true
}

validate_description :: proc(desc: Description, allocator := context.allocator) -> errs.Error {
	if len(desc.command) == 0 || desc.command[0] == "" {
		return errs.new(.Invalid_Input, "process: command requires a nonempty executable", allocator = allocator)
	}
	if len(desc.command) > MAX_ARGUMENTS {
		return errs.newf(.Resource_Limit, "process: command exceeds the %d-argument budget", MAX_ARGUMENTS, allocator = allocator)
	}
	if len(desc.environment) > MAX_ENVIRONMENT_ENTRIES {
		return errs.newf(
			.Resource_Limit,
			"process: environment exceeds the %d-entry budget",
			MAX_ENVIRONMENT_ENTRIES,
			allocator = allocator,
		)
	}

	total := 0
	account :: proc(total: ^int, text: string, allocator := context.allocator) -> errs.Error {
		if strings.index_byte(text, 0) >= 0 {
			return errs.new(.Invalid_Input, "process: arguments, paths, and environment entries cannot contain NUL", allocator = allocator)
		}
		if len(text) > MAX_SPAWN_BYTES - total^ {
			return errs.newf(.Resource_Limit, "process: spawn input exceeds the %d-byte budget", MAX_SPAWN_BYTES, allocator = allocator)
		}
		total^ += len(text)
		return {}
	}

	for argument in desc.command {
		if err := account(&total, argument, allocator); !errs.ok(err) {
			return err
		}
	}
	if err := account(&total, desc.working_dir, allocator); !errs.ok(err) {
		return err
	}
	for entry in desc.environment {
		separator := strings.index_byte(entry, '=')
		if separator <= 0 {
			return errs.new(.Invalid_Input, "process: environment entries must have a nonempty KEY=VALUE key", allocator = allocator)
		}
		if err := account(&total, entry, allocator); !errs.ok(err) {
			return err
		}
	}
	return {}
}

spawn :: proc(desc: Description, allocator := context.allocator) -> (Handle, errs.Error) {
	if err := validate_description(desc, allocator); !errs.ok(err) {
		return {}, err
	}
	return platform_spawn(desc, allocator)
}

// wait blocks the calling thread until the child exits, reaps it, and
// releases the native process handle. It does not close the pipe endpoints.
// It is a low-level primitive; the job service owns asynchronous lifecycle
// polling rather than calling this on the UI thread.
wait :: proc(handle: ^Handle, allocator := context.allocator) -> (Exit_Status, errs.Error) {
	if handle == nil || handle.process == 0 {
		return {}, errs.new(.Invalid_Input, "process: wait requires a live owned process handle", allocator = allocator)
	}
	return platform_wait(handle, allocator)
}

// destroy is idempotent after wait and closes any remaining parent pipes.
// Destroying a Handle that still owns a running process is a programmer
// error: detaching it would make Linux reaping and job cancellation unclear.
destroy :: proc(handle: ^Handle, allocator := context.allocator) -> errs.Error {
	if handle == nil {
		return {}
	}
	assert(handle.process == 0, "process: wait must reap the child before destroy")
	first: errs.Error
	pipes := []^Pipe{&handle.stdin, &handle.stdout, &handle.stderr}
	for pipe in pipes {
		if !pipe.open {
			continue
		}
		err := close_pipe(pipe, allocator)
		if first.kind == .None {
			first = err
		} else {
			errs.destroy(&err)
		}
	}
	handle^ = {}
	return first
}
