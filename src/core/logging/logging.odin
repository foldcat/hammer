// Package logging: the editor's logging and fatal-error-reporting
// subsystem.
//
// Single instance by design (AGENTS.md §13): `init` once at startup,
// `shutdown` once at exit, and only on the thread that owns the
// subsystem. `init` is not thread-safe and must complete before any
// worker thread starts; `shutdown` must run after all workers have
// stopped and after the last log call.
//
// Thread safety of emission: every log line is dispatched under an
// internal mutex, so workers may log from their own threads (M01.05) as
// long as each thread's `context.logger` is the logger returned by
// `logger()` — see `install`.
//
// Log files are bounded by truncation: if the file at `file_path` is
// larger than `MAX_FILE_SIZE` when opened, it is truncated. Rotation is
// deliberately not implemented yet (a later milestone, together with
// recovery-journal rotation).
//
// Failure policy: a file that cannot be opened does not disable logging.
// `init` still installs the console sink and returns an `errs.Error`
// describing the file failure; callers log a warning and continue.
//
// Panic reporting: `panic_proc` is installed as
// `context.assertion_failure_proc` (via `install`). It best-effort
// persists the panic message into the log file, then hands off to
// `runtime.default_assertion_failure_proc`, which prints to stderr and
// aborts. It never takes the emit mutex: the panic may have fired while
// that mutex was held.
package logging

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

import errs "../errs"

// MAX_FILE_SIZE is the largest log file kept across runs; a larger
// existing file is truncated when opened.
MAX_FILE_SIZE :: 1 << 20 // 1 MiB

Options :: struct {
	file_path: string, // "" disables file logging (console only)
	ident: string, // short tag printed in every line, e.g. "hammer"
	lowest: log.Level, // minimum level; zero value = .Debug
}

// Subsystem state. Single instance: protected by the ownership rules in
// the package comment, not by a lock.
g: struct {
	initialized: bool,
	mutex:       sync.Mutex,
	sinks: struct {
		console, file: log.Logger,
	},
	allocator: mem.Allocator, // allocator for owned strings and sink data
	file_path: string, // owned copy of the log file path ("" = off)
}

// init initializes the subsystem with the given options. On success the
// returned error is the no-error sentinel. If the log file cannot be
// opened, the subsystem still initializes with the console sink and the
// returned error describes the file failure; `shutdown` remains
// required. Calling init twice returns an `.Internal` error.
init :: proc(options: Options, allocator := context.allocator) -> errs.Error {
	if g.initialized {
		return errs.newf(.Internal, "logging.init called twice", allocator = allocator)
	}
	if options.lowest < log.Level.Debug || options.lowest > log.Level.Fatal {
		return errs.newf(
			.Invalid_Input,
			"logging.init: level %v out of range",
			options.lowest,
			allocator = allocator,
		)
	}

	g.allocator = allocator
	g.initialized = true
	g.sinks.console = log.create_console_logger(
		lowest = options.lowest,
		ident = options.ident,
		allocator = allocator,
	)

	if options.file_path != "" {
		f, ferr := _open_log_file(options.file_path)
		if ferr != nil {
			return errs.newf(
				.IO,
				"logging.init: cannot open log file %s: %v",
				options.file_path,
				ferr,
				allocator = allocator,
			)
		}
		g.sinks.file = log.create_file_logger(
			f,
			options.lowest,
			log.Default_File_Logger_Opts,
			options.ident,
			allocator,
		)
		g.file_path = strings.clone(options.file_path, allocator)
	}

	return errs.Error{}
}

// shutdown flushes and closes the file sink and destroys the sink
// loggers. Idempotent: calling it when uninitialized is a no-op.
shutdown :: proc() {
	if !g.initialized {
		return
	}
	if g.file_path != "" {
		if data := cast(^log.File_Console_Logger_Data)g.sinks.file.data; data != nil && data.file_handle != nil {
			// Best effort; the process is about to exit anyway.
			os.flush(data.file_handle)
		}
		log.destroy_file_logger(g.sinks.file, g.allocator)
		delete(g.file_path, g.allocator)
	}
	log.destroy_console_logger(g.sinks.console, g.allocator)
	g = {}
}

// logger returns the thread-safe logger to install into
// `context.logger` (see `install`).
logger :: proc() -> log.Logger {
	return log.Logger{
		procedure = _emit,
		data = nil,
		lowest_level = .Debug,
		options = nil,
	}
}

// install sets `ctx.logger` to the editor logger and
// `ctx.assertion_failure_proc` to the panic reporter. Call it for every
// thread that logs (the UI thread at startup, each worker at spawn).
install :: proc(ctx: ^runtime.Context) {
	ctx.logger = logger()
	ctx.assertion_failure_proc = panic_proc
}

// panic_proc reports panics and failed assertions into the log file and
// then hands off to the runtime default handler (stderr + abort). It
// never locks the emit mutex: the panic may have fired while that mutex
// was held, and a locked panic path would hang instead of reporting.
panic_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if g.initialized && g.sinks.file.procedure != nil {
		if data := cast(^log.File_Console_Logger_Data)g.sinks.file.data; data != nil && data.file_handle != nil {
			fmt.fprintf(
				data.file_handle,
				"[PANIC ] [%s:%d:%s()] %s: %s\n",
				loc.file_path,
				loc.line,
				loc.procedure,
				prefix,
				message,
			)
		}
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// _emit is the composed sink dispatcher. It serializes all emission, so
// a single line is never interleaved with another thread's line.
_emit :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location: runtime.Source_Code_Location,
) {
	sync.mutex_lock(&g.mutex)
	if g.sinks.file.procedure != nil && level >= g.sinks.file.lowest_level {
		g.sinks.file.procedure(g.sinks.file.data, level, text, g.sinks.file.options, location)
	}
	if g.sinks.console.procedure != nil && level >= g.sinks.console.lowest_level {
		g.sinks.console.procedure(g.sinks.console.data, level, text, g.sinks.console.options, location)
	}
	sync.mutex_unlock(&g.mutex)
}

// _open_log_file opens `path` for appending, truncating it first when an
// existing file exceeds MAX_FILE_SIZE. The caller owns the returned
// handle (transferred to the file sink by init).
_open_log_file :: proc(path: string) -> (^os.File, os.Error) {
	if f, err := os.open(path, os.File_Flags{.Read}); err == nil {
		size, serr := os.file_size(f)
		os.close(f)
		if serr == nil && size > MAX_FILE_SIZE {
			return os.open(path, os.File_Flags{.Write, .Create, .Trunc})
		}
	}
	return os.open(path, os.File_Flags{.Write, .Create, .Append})
}
