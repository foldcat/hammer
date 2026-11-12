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
import input "core/input"

State :: struct {
	pass_action:     sg.Pass_Action,
	frame_count:     i64,
	autoquit_frames: i64, // 0 = disabled
	test_panic:      bool,
	// scale is the editor-owned, always-valid physical/logical ratio
	// (M01.04). window_metrics validates the backend value and falls
	// back to 1.0; input normalization trusts this cached value, so
	// the external input is validated once, at the boundary.
	scale:           f32,
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
	case .KEY_DOWN, .KEY_UP, .CHAR, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL:
		// M01.04: normalize the backend event into an editor input
		// event (logical coordinates, editor keys, validated text)
		// and dispatch. M06/M07 replace the ESC handling with the
		// shortcut and chord layers.
		e, ok := normalize_sapp_event(ev)
		if !ok {
			return
		}
		log_input_event(e)
		if kd, is_down := e.(input.Key_Down); is_down && !kd.repeat && kd.key == .Escape {
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
	// The cached, always-valid scale that input normalization uses
	// (M01.04); refreshed here and only here.
	state.scale = scale
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

// ---- Input normalization (M01.04) --------------------------------------
//
// The application layer owns every backend-specific mapping; the core
// input package carries only editor semantics (M01 acceptance: no
// dependency-specific code leaks into the core).

// sokol_key_map translates sokol_app keycodes into editor keys. Gaps
// and unknown keycodes read as input.Key.Invalid; WORLD_1/WORLD_2 are
// layout-dependent non-US keys and stay unmapped on purpose.
sokol_key_map := [int(sapp.Keycode.MENU) + 1]input.Key {
	int(sapp.Keycode.SPACE) = .Space,
	int(sapp.Keycode.APOSTROPHE) = .Apostrophe,
	int(sapp.Keycode.COMMA) = .Comma,
	int(sapp.Keycode.MINUS) = .Minus,
	int(sapp.Keycode.PERIOD) = .Period,
	int(sapp.Keycode.SLASH) = .Slash,
	int(sapp.Keycode._0) = .D0,
	int(sapp.Keycode._1) = .D1,
	int(sapp.Keycode._2) = .D2,
	int(sapp.Keycode._3) = .D3,
	int(sapp.Keycode._4) = .D4,
	int(sapp.Keycode._5) = .D5,
	int(sapp.Keycode._6) = .D6,
	int(sapp.Keycode._7) = .D7,
	int(sapp.Keycode._8) = .D8,
	int(sapp.Keycode._9) = .D9,
	int(sapp.Keycode.SEMICOLON) = .Semicolon,
	int(sapp.Keycode.EQUAL) = .Equal,
	int(sapp.Keycode.A) = .A,
	int(sapp.Keycode.B) = .B,
	int(sapp.Keycode.C) = .C,
	int(sapp.Keycode.D) = .D,
	int(sapp.Keycode.E) = .E,
	int(sapp.Keycode.F) = .F,
	int(sapp.Keycode.G) = .G,
	int(sapp.Keycode.H) = .H,
	int(sapp.Keycode.I) = .I,
	int(sapp.Keycode.J) = .J,
	int(sapp.Keycode.K) = .K,
	int(sapp.Keycode.L) = .L,
	int(sapp.Keycode.M) = .M,
	int(sapp.Keycode.N) = .N,
	int(sapp.Keycode.O) = .O,
	int(sapp.Keycode.P) = .P,
	int(sapp.Keycode.Q) = .Q,
	int(sapp.Keycode.R) = .R,
	int(sapp.Keycode.S) = .S,
	int(sapp.Keycode.T) = .T,
	int(sapp.Keycode.U) = .U,
	int(sapp.Keycode.V) = .V,
	int(sapp.Keycode.W) = .W,
	int(sapp.Keycode.X) = .X,
	int(sapp.Keycode.Y) = .Y,
	int(sapp.Keycode.Z) = .Z,
	int(sapp.Keycode.LEFT_BRACKET) = .Left_Bracket,
	int(sapp.Keycode.BACKSLASH) = .Backslash,
	int(sapp.Keycode.RIGHT_BRACKET) = .Right_Bracket,
	int(sapp.Keycode.GRAVE_ACCENT) = .Grave_Accent,
	int(sapp.Keycode.ESCAPE) = .Escape,
	int(sapp.Keycode.ENTER) = .Enter,
	int(sapp.Keycode.TAB) = .Tab,
	int(sapp.Keycode.BACKSPACE) = .Backspace,
	int(sapp.Keycode.INSERT) = .Insert,
	int(sapp.Keycode.DELETE) = .Delete,
	int(sapp.Keycode.RIGHT) = .Right,
	int(sapp.Keycode.LEFT) = .Left,
	int(sapp.Keycode.DOWN) = .Down,
	int(sapp.Keycode.UP) = .Up,
	int(sapp.Keycode.PAGE_UP) = .Page_Up,
	int(sapp.Keycode.PAGE_DOWN) = .Page_Down,
	int(sapp.Keycode.HOME) = .Home,
	int(sapp.Keycode.END) = .End,
	int(sapp.Keycode.CAPS_LOCK) = .Caps_Lock,
	int(sapp.Keycode.SCROLL_LOCK) = .Scroll_Lock,
	int(sapp.Keycode.NUM_LOCK) = .Num_Lock,
	int(sapp.Keycode.PRINT_SCREEN) = .Print_Screen,
	int(sapp.Keycode.PAUSE) = .Pause,
	int(sapp.Keycode.F1) = .F1,
	int(sapp.Keycode.F2) = .F2,
	int(sapp.Keycode.F3) = .F3,
	int(sapp.Keycode.F4) = .F4,
	int(sapp.Keycode.F5) = .F5,
	int(sapp.Keycode.F6) = .F6,
	int(sapp.Keycode.F7) = .F7,
	int(sapp.Keycode.F8) = .F8,
	int(sapp.Keycode.F9) = .F9,
	int(sapp.Keycode.F10) = .F10,
	int(sapp.Keycode.F11) = .F11,
	int(sapp.Keycode.F12) = .F12,
	int(sapp.Keycode.F13) = .F13,
	int(sapp.Keycode.F14) = .F14,
	int(sapp.Keycode.F15) = .F15,
	int(sapp.Keycode.F16) = .F16,
	int(sapp.Keycode.F17) = .F17,
	int(sapp.Keycode.F18) = .F18,
	int(sapp.Keycode.F19) = .F19,
	int(sapp.Keycode.F20) = .F20,
	int(sapp.Keycode.F21) = .F21,
	int(sapp.Keycode.F22) = .F22,
	int(sapp.Keycode.F23) = .F23,
	int(sapp.Keycode.F24) = .F24,
	int(sapp.Keycode.F25) = .F25,
	int(sapp.Keycode.KP_0) = .KP_0,
	int(sapp.Keycode.KP_1) = .KP_1,
	int(sapp.Keycode.KP_2) = .KP_2,
	int(sapp.Keycode.KP_3) = .KP_3,
	int(sapp.Keycode.KP_4) = .KP_4,
	int(sapp.Keycode.KP_5) = .KP_5,
	int(sapp.Keycode.KP_6) = .KP_6,
	int(sapp.Keycode.KP_7) = .KP_7,
	int(sapp.Keycode.KP_8) = .KP_8,
	int(sapp.Keycode.KP_9) = .KP_9,
	int(sapp.Keycode.KP_DECIMAL) = .KP_Decimal,
	int(sapp.Keycode.KP_DIVIDE) = .KP_Divide,
	int(sapp.Keycode.KP_MULTIPLY) = .KP_Multiply,
	int(sapp.Keycode.KP_SUBTRACT) = .KP_Subtract,
	int(sapp.Keycode.KP_ADD) = .KP_Add,
	int(sapp.Keycode.KP_ENTER) = .KP_Enter,
	int(sapp.Keycode.KP_EQUAL) = .KP_Equal,
	int(sapp.Keycode.LEFT_SHIFT) = .Left_Shift,
	int(sapp.Keycode.LEFT_CONTROL) = .Left_Control,
	int(sapp.Keycode.LEFT_ALT) = .Left_Alt,
	int(sapp.Keycode.LEFT_SUPER) = .Left_Super,
	int(sapp.Keycode.RIGHT_SHIFT) = .Right_Shift,
	int(sapp.Keycode.RIGHT_CONTROL) = .Right_Control,
	int(sapp.Keycode.RIGHT_ALT) = .Right_Alt,
	int(sapp.Keycode.RIGHT_SUPER) = .Right_Super,
	int(sapp.Keycode.MENU) = .Menu,
}

// sokol_modifiers translates the backend modifier mask (modifier keys
// only; mouse-button bits are ignored here).
sokol_modifiers :: proc(mask: u32) -> input.Modifiers {
	mods: input.Modifiers
	if mask & sapp.MODIFIER_SHIFT != 0 {
		mods += {.Shift}
	}
	if mask & sapp.MODIFIER_CTRL != 0 {
		mods += {.Ctrl}
	}
	if mask & sapp.MODIFIER_ALT != 0 {
		mods += {.Alt}
	}
	if mask & sapp.MODIFIER_SUPER != 0 {
		mods += {.Super}
	}
	return mods
}

// sokol_buttons extracts the held-button set from the backend
// modifier mask (sokol_app reports held mouse buttons there).
sokol_buttons :: proc(mask: u32) -> input.Mouse_Buttons {
	buttons: input.Mouse_Buttons
	if mask & sapp.MODIFIER_LMB != 0 {
		buttons += {.Left}
	}
	if mask & sapp.MODIFIER_RMB != 0 {
		buttons += {.Right}
	}
	if mask & sapp.MODIFIER_MMB != 0 {
		buttons += {.Middle}
	}
	return buttons
}

// sokol_button_to_input maps a backend mouse button; unrecognized
// values return ok=false and the event is dropped by the caller (the
// editor Mouse_Button type has no Invalid member — see core/input).
sokol_button_to_input :: proc(b: sapp.Mousebutton) -> (input.Mouse_Button, bool) {
	#partial switch b {
	case .LEFT:
		return .Left, true
	case .MIDDLE:
		return .Middle, true
	case .RIGHT:
		return .Right, true
	case:
	}
	return {}, false
}

// normalize_sapp_event translates one backend event into an editor
// input event (M01.04). ok=false means the event has no editor
// equivalent (non-input events, unrecognized buttons, invalid text).
// Pointer coordinates are converted from framebuffer pixels to
// logical units with core/coords, using the validated scale cached by
// window_metrics — DPI is applied exactly once, at this boundary.
normalize_sapp_event :: proc(ev: ^sapp.Event) -> (input.Event, bool) {
	scale := state.scale
	#partial switch ev.type {
	case .KEY_DOWN:
		return input.Key_Down {
			key = sokol_key_map[int(ev.key_code)],
			repeat = ev.key_repeat,
			modifiers = sokol_modifiers(ev.modifiers),
		}, true
	case .KEY_UP:
		return input.Key_Up {
			key = sokol_key_map[int(ev.key_code)],
			modifiers = sokol_modifiers(ev.modifiers),
		}, true
	case .CHAR:
		text, terr := input.normalize_text(ev.char_code)
		if !errs.ok(terr) {
			log.warnf("input: %v (event dropped)", errs.describe(terr))
			errs.destroy(&terr)
			return {}, false
		}
		return input.Text{text = text, modifiers = sokol_modifiers(ev.modifiers)}, true
	case .MOUSE_DOWN, .MOUSE_UP:
		button, b_ok := sokol_button_to_input(ev.mouse_button)
		if !b_ok {
			return {}, false
		}
		pos, perr := coords.to_logical_point(
			coords.Physical_Point{ev.mouse_x, ev.mouse_y},
			scale,
		)
		if !errs.ok(perr) {
			// state.scale is validated at the boundary; this is a
			// defensive path only.
			errs.destroy(&perr)
			return {}, false
		}
		mods := sokol_modifiers(ev.modifiers)
		if ev.type == .MOUSE_DOWN {
			return input.Pointer_Down{button = button, pos = pos, modifiers = mods}, true
		}
		return input.Pointer_Up{button = button, pos = pos, modifiers = mods}, true
	case .MOUSE_MOVE:
		pos, perr := coords.to_logical_point(
			coords.Physical_Point{ev.mouse_x, ev.mouse_y},
			scale,
		)
		if !errs.ok(perr) {
			errs.destroy(&perr)
			return {}, false
		}
		return input.Pointer_Move {
			pos = pos,
			buttons = sokol_buttons(ev.modifiers),
			modifiers = sokol_modifiers(ev.modifiers),
		}, true
	case .MOUSE_SCROLL:
		pos, perr := coords.to_logical_point(
			coords.Physical_Point{ev.mouse_x, ev.mouse_y},
			scale,
		)
		if !errs.ok(perr) {
			errs.destroy(&perr)
			return {}, false
		}
		return input.Scroll {
			pos = pos,
			dx = ev.scroll_x,
			dy = ev.scroll_y,
			modifiers = sokol_modifiers(ev.modifiers),
		}, true
	}
	return {}, false
}

// log_input_event logs a normalized event for diagnostics. Pointer
// moves are the high-frequency event and are not logged, keeping the
// log bounded; the headless input smoke greps the remaining lines.
log_input_event :: proc(e: input.Event) {
	#partial switch _ in e {
	case input.Pointer_Move:
		return
	case:
	}
	log.debugf("input: %s", input.describe(e))
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
	state.scale = 1.0 // replaced by window_metrics before any input event
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
