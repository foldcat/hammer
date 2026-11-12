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
import mem_virtual "core:mem/virtual"
import "core:os"
import "core:strconv"

import sapp "sokol:app"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

import "core/errs"
import "core/lifecycle"
import "core/logging"
import "platform"

import generated "config/generated"
import coords "core/coords"
import config "core/config"

State :: struct {
	pass_action:     sg.Pass_Action,
	frame_count:     i64,
	autoquit_frames: i64, // 0 = disabled
	test_panic:      bool,
}

state: State

// cfg is the configuration compiled into the binary (M01.02): the
// generated package staged by make.odin from the trusted user config.
// It is static data owned by the generated package; never freed.
cfg: config.Resolved

// app is the single lifecycle owner for the process (AGENTS.md §13:
// one mutation owner). All transitions go through the lifecycle procs.
app: lifecycle.App

// services is the Sokol-backed implementation of the platform service
// interfaces; the core consumes only these proc pointers.
services: platform.Services

// Allocation layout (AGENTS.md §10.5, SPECS.md §17.4):
//
//   - `perm` is the permanent arena. Every allocation that lives for the
//     whole program — logging sink data, config-derived strings, errors
//     owned by the lifecycle — goes here and is released in one shot at
//     the end of main.
//   - `temp` is the frame-scratch arena, installed as
//     `context.temp_allocator`; it is reset at the end of every frame.
//     Nothing may borrow from it across frames.
//   - Until `init_arenas` has succeeded, `permanent` returns the panic
//     allocator: an allocation before arena setup is a loud bug, not a
//     leak.
perm: mem_virtual.Arena
perm_ready := false

temp: mem_virtual.Arena

// permanent returns the allocator for program-lifetime data.
permanent :: proc() -> mem.Allocator {
	if !perm_ready {
		return mem.panic_allocator()
	}
	return mem_virtual.arena_allocator(&perm)
}

// init_arenas reserves the permanent and frame-scratch arenas. It must
// run before any other app code: `permanent` panics on use until it has
// succeeded. Failure is fatal and reported with raw writes — formatting
// would allocate, and the panic allocator is still in force here.
init_arenas :: proc() -> bool {
	if err := mem_virtual.arena_init_growing(&perm); err != nil {
		os.write_string(os.stderr, "hammer: fatal: cannot create the permanent arena\n")
		return false
	}
	perm_ready = true
	if err := mem_virtual.arena_init_growing(&temp); err != nil {
		mem_virtual.arena_destroy(&perm)
		perm_ready = false
		os.write_string(os.stderr, "hammer: fatal: cannot create the frame-scratch arena\n")
		return false
	}
	return true
}

// app_context returns the context used by main and all Sokol callbacks:
// default per-thread state, the permanent arena as the default
// allocator, the frame-scratch arena as the temp allocator, the editor
// logger, and the panic reporter.
app_context :: proc() -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = permanent()
	ctx.temp_allocator = mem_virtual.arena_allocator(&temp)
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

	sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
	if !sg.isvalid() {
		request_quit(.Init_Failed, "init", errs.new(.Internal, "sokol gfx setup failed"))
		return
	}

	// The window clear color is the configured body background: config
	// edits visibly change the rendered output after a rebuild (M01
	// acceptance). M01.06 replaces this with real column/tag/body
	// rectangles painted from the same theme.
	c := cfg.Theme.Body_Bg
	state.pass_action.colors[0] = {
		load_action = .CLEAR,
		clear_value = sg.Color{c[0], c[1], c[2], c[3]},
	}

	// First real consumption of the platform window service: physical
	// framebuffer metrics converted to logical layout units through
	// core/coords (M01.03). A garbage scale degrades to 1.0 instead of
	// crashing (M01 acceptance).
	_, _, scale := window_metrics("window")

	// The font point size through the §9.6 chain: points → logical px
	// (×96/72) → physical px (× scale). M05 turns this into the
	// rendering font size; logging it now pins the wiring end to end.
	font_px, ferr := coords.points_to_physical_px(cfg.Font_Size_Points, scale)
	if errs.ok(ferr) {
		log.infof(
			"font: %vpt = %v logical px = %v physical px",
			cfg.Font_Size_Points,
			coords.points_to_logical_px(cfg.Font_Size_Points),
			font_px,
		)
	} else {
		log.warnf("font: %v (using points → logical px only)", errs.describe(ferr))
		errs.destroy(&ferr)
	}
	desc := config.describe(cfg, context.temp_allocator)
	log.info(desc)
}

frame :: proc "c" () {
	context = app_context()

	// Reclaim the frame scratch arena at the end of every frame. All
	// frame-local allocations (log-line formatting, config.describe,
	// env reads) land in `temp` via context.temp_allocator and must
	// never be held across this reset (AGENTS.md §10.5).
	defer mem_virtual.arena_free_all(&temp)

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
		// Resize must survive any scale value the backend reports
		// (M01 acceptance): the conversion validates and falls back.
		window_metrics("window resized", log.Level.Debug)
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
	options := logging.Options {
		ident = "hammer",
	}
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
	return logging.init(options, permanent())
}

// default_log_path returns the per-user log file path (frame-scratch
// allocation; borrowed until the next frame reset — logging.init clones
// it into the permanent arena before then). Falls back to ""
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
	services = platform.Services {
		window = platform.Window_Service {
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

// window_metrics fetches the physical window metrics from the backend
// and converts them to logical layout units with core/coords (M01.03).
// An invalid scale (zero, negative, non-finite, absurd) is reported
// and falls back to 1.0 — logical equals physical — so a broken DPI
// value degrades instead of crashing (M01 acceptance).
window_metrics :: proc(
	what: string,
	level := log.Level.Info,
) -> (
	physical: coords.Physical_Size,
	logical: coords.Logical_Size,
	scale: f32,
) {
	width, height := services.window.framebuffer_size(services.user)
	scale = services.window.dpi_scale(services.user)
	physical = coords.Physical_Size{f32(width), f32(height)}
	converted, err := coords.to_logical_size(physical, scale)
	if !errs.ok(err) {
		log.logf(log.Level.Error, "window: %v (falling back to scale 1.0)", errs.describe(err))
		errs.destroy(&err)
		logical = coords.Logical_Size{physical.width, physical.height}
		scale = 1.0
	} else {
		logical = converted
	}
	log.logf(
		level,
		"%s: %vx%v px, %vx%v logical, dpi_scale=%.2f, backend=%v",
		what,
		width,
		height,
		logical.width,
		logical.height,
		scale,
		sg.query_backend(),
	)
	return
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

main :: proc() {
	if !init_arenas() {
		os.exit(1)
	}
	// Defers execute in reverse declaration order (LIFO): app_destroy,
	// logging.shutdown (the last log call precedes it), then a single
	// free_all of the permanent arena (releasing every program-lifetime
	// allocation at once), then the arena reservations themselves —
	// every arena is free_all'ed and destroyed (AGENTS.md §10.5).
	defer mem_virtual.arena_destroy(&temp)
	defer mem_virtual.arena_free_all(&temp)
	defer mem_virtual.arena_destroy(&perm)
	defer mem_virtual.arena_free_all(&perm)
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
	cfg = generated.resolved

	log.infof("hammer starting (pid=%d, os=%v, arch=%v)", os.get_pid(), ODIN_OS, ODIN_ARCH)

	setup_services()
	lifecycle.app_enter_initializing(&app)

	sapp.run(
		{
			init_cb = init,
			frame_cb = frame,
			cleanup_cb = cleanup,
			event_cb = event,
			width = 800,
			height = 600,
			window_title = "Hammer",
			icon = {sokol_default = true},
			logger = {func = slog.func},
		},
	)

	finalize_lifecycle()
}
