// Hammer application entry (package main).
//
// This file is the application layer (SPECS.md §3.2): it implements the
// platform service interfaces (src/platform) with Sokol and drives the
// editor core (src/core/lifecycle, src/core/logging, src/core/errs) from
// the Sokol callbacks. The core never imports Sokol.
//
// Test hooks (all ignored unless set):
//   HAMMER_AUTOQUIT_FRAMES=<n>  request quit after n frames (headless smoke test)
//   HAMMER_TEST_PANIC=1         panic during frame 2 (panic-reporting smoke test)
//   HAMMER_LOG=<path>           log file path; empty string disables file logging
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"

import sapp "sokol:app"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

import "core/logging"
import "core/lifecycle"
import "core/errs"
import "platform"

State :: struct {
	pass_action:     sg.Pass_Action,
	frame_count:     i64,
	autoquit_frames: i64, // 0 = disabled
	test_panic:      bool,
}

state: State

// app is the single lifecycle owner for the process (AGENTS.md §13:
// one mutation owner). All transitions go through the lifecycle procs.
app: lifecycle.App

// services is the Sokol-backed implementation of the platform service
// interfaces; the core consumes only these proc pointers.
services: platform.Services

// track reports leaked/incorrectly-freed allocations at exit; every
// context used by the app (main + callbacks) allocates through it.
track: mem.Tracking_Allocator

// app_context returns the context used by main and all Sokol callbacks:
// default per-thread state, the tracking allocator, the editor logger,
// and the panic reporter.
app_context :: proc() -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = mem.tracking_allocator(&track)
	logging.install(&ctx)
	return ctx
}

// request_quit records the quit in the lifecycle, logs it, and asks the
// backend to quit. `err` (required for fatal reasons) transfers
// ownership to the lifecycle on success only.
request_quit :: proc(reason: lifecycle.Quit_Reason, source: string, err := errs.Error{}) {
	lifecycle.app_request_quit(&app, reason, err)
	log.infof("lifecycle: quit requested (reason=%v, source=%s)", reason, source)
	sapp.request_quit()
}

init :: proc "c" () {
	context = app_context()

	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	if !sg.isvalid() {
		request_quit(.Init_Failed, "init", errs.new(.Internal, "sokol gfx setup failed"))
		return
	}

	state.pass_action.colors[0] = {
		load_action = .CLEAR,
		clear_value = {0.10, 0.12, 0.15, 1.0},
	}

	// First real consumption of the platform window service.
	width, height := services.window.framebuffer_size(services.user)
	scale := services.window.dpi_scale(services.user)
	log.infof("window: %dx%d px, dpi_scale=%.2f, backend=%v", width, height, scale, sg.query_backend())
}

frame :: proc "c" () {
	context = app_context()

	state.frame_count += 1

	if app.phase == .Initializing {
		lifecycle.app_enter_running(&app)
		log.info("lifecycle: running")
	}

	if app.phase == .Running {
		if state.test_panic && state.frame_count >= 2 {
			// Exercises the panic-reporting path end to end: the
			// message must land in the log file and the process must
			// exit nonzero.
			panic("hammer test panic (HAMMER_TEST_PANIC)")
		}
		if state.autoquit_frames > 0 && state.frame_count >= state.autoquit_frames {
			request_quit(.Autoquit, "autoquit")
		}
	}

	sg.begin_pass({action = state.pass_action, swapchain = sglue.swapchain()})
	sg.end_pass()
	sg.commit()
}

event :: proc "c" (ev: ^sapp.Event) {
	context = app_context()

	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key_code == .ESCAPE {
			request_quit(.User_Request, "esc")
		}
	case .QUIT_REQUESTED:
		// Window close button / OS close. M04.06 inserts the
		// dirty-buffer review before this unconditional quit.
		request_quit(.User_Request, "window-close")
	case .RESIZED:
		width, height := services.window.framebuffer_size(services.user)
		scale := services.window.dpi_scale(services.user)
		log.debugf("window resized: %dx%d px, dpi_scale=%.2f", width, height, scale)
	}
}

cleanup :: proc "c" () {
	context = app_context()

	sg.shutdown()
	lifecycle.app_enter_shutdown(&app)
	log.infof(
		"lifecycle: shutdown (phase=%v, quit_reason=%v, frames=%v)",
		app.phase,
		app.quit_reason,
		state.frame_count,
	)
}

// finalize_lifecycle normalizes the phase after sapp.run returns. The
// cleanup callback normally moved the app to .Shutdown; if the backend
// returned without it, drive the remaining transitions here so the exit
// path is uniform and the fatal error is reported either way.
finalize_lifecycle :: proc() {
	#partial switch app.phase {
	case .Initializing, .Running:
		log.warnf("backend returned while lifecycle phase was %v; recording quit", app.phase)
		lifecycle.app_request_quit(&app, .User_Request)
		lifecycle.app_enter_shutdown(&app)
	case .Quitting:
		lifecycle.app_enter_shutdown(&app)
	case .Shutdown, .Exited:
	}
	if !errs.ok(app.fatal_error) {
		log.errorf("fatal: %v", errs.describe(app.fatal_error))
	}
	lifecycle.app_enter_exited(&app)
	log.infof("lifecycle: exited (quit_reason=%v)", app.quit_reason)
}

// setup_logging initializes the logging subsystem. The log path is
// HAMMER_LOG when set (empty = console only), otherwise the per-user
// state directory. A file that cannot be opened is not fatal: init
// leaves console logging active and reports the failure.
setup_logging :: proc() -> errs.Error {
	options := logging.Options{ident = "hammer"}
	if path, found := os.lookup_env("HAMMER_LOG", context.temp_allocator); found {
		options.file_path = path // "" disables file logging
	} else {
		options.file_path = default_log_path()
	}
	if options.file_path != "" {
		// init does not create directories; best effort, failure is
		// reported by init itself.
		os.make_directory_all(parent_dir(options.file_path))
	}
	return logging.init(options)
}

// default_log_path returns the per-user log file path (scratch
// allocation; borrowed until the next scratch reset). Falls back to ""
// (console only) when no writable base can be determined.
default_log_path :: proc() -> string {
	if xdg, found := os.lookup_env("XDG_STATE_HOME", context.temp_allocator); found && xdg != "" {
		return fmt.tprintf("%s/hammer/log/hammer.log", xdg)
	}
	if home, found := os.lookup_env("HOME", context.temp_allocator); found && home != "" {
		return fmt.tprintf("%s/.local/state/hammer/log/hammer.log", home)
	}
	return ""
}

// parent_dir returns the directory part of `path` (borrowed slice into
// `path`, valid until `path`'s backing storage changes).
parent_dir :: proc(path: string) -> string {
	last := 0
	for r, i in path {
		if r == '/' || r == '\\' {
			last = i + 1
		}
	}
	return path[:last]
}

// setup_services wires the Sokol-backed implementations into the
// platform service table.
setup_services :: proc() {
	services = platform.Services{
		window = platform.Window_Service{
			framebuffer_size = sokol_framebuffer_size,
			dpi_scale = sokol_dpi_scale,
		},
	}
}

sokol_framebuffer_size :: proc(user: rawptr) -> (width, height: i32) {
	return i32(sapp.width()), i32(sapp.height())
}

sokol_dpi_scale :: proc(user: rawptr) -> f32 {
	return sapp.dpi_scale()
}

// Test hook used by the headless smoke test; unset in normal use.
autoquit_frames_from_env :: proc() -> i64 {
	value, found := os.lookup_env("HAMMER_AUTOQUIT_FRAMES", context.temp_allocator)
	if !found {
		return 0
	}
	frames, ok := strconv.parse_i64(value)
	if !ok || frames <= 0 {
		return 0
	}
	return min(frames, 100_000)
}

// env_flag reports whether a boolean test hook is set ("1", "true",
// anything non-empty except "0"/"false").
env_flag :: proc(name: string) -> bool {
	value, found := os.lookup_env(name, context.temp_allocator)
	if !found {
		return false
	}
	return value != "" && value != "0" && value != "false"
}

// report_leaks prints exit-time allocation statistics to stderr. It runs
// after logging shutdown (the logger's own allocations must already be
// released, and stderr is the honest channel for terminal diagnostics —
// the log file is closed by then).
report_leaks :: proc(track: ^mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
}

main :: proc() {
	mem.tracking_allocator_init(&track, context.allocator)
	// Defers execute in reverse declaration order (LIFO):
	// app_destroy -> logging.shutdown -> report_leaks -> tracking_destroy.
	defer mem.tracking_allocator_destroy(&track)
	defer report_leaks(&track)
	defer logging.shutdown()
	defer lifecycle.app_destroy(&app)

	context = app_context()

	if init_err := setup_logging(); !errs.ok(init_err) {
		// Console logging is already live; the file sink is off.
		log.warnf("logging: %v (continuing console-only)", errs.describe(init_err))
		errs.destroy(&init_err)
	}

	state.autoquit_frames = autoquit_frames_from_env()
	state.test_panic = env_flag("HAMMER_TEST_PANIC")

	log.infof("hammer starting (pid=%d, os=%v, arch=%v)", os.get_pid(), ODIN_OS, ODIN_ARCH)

	setup_services()
	lifecycle.app_enter_initializing(&app)

	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		event_cb = event,
		width = 800,
		height = 600,
		window_title = "Hammer",
		icon = {sokol_default = true},
		logger = {func = slog.func},
	})

	finalize_lifecycle()
}
