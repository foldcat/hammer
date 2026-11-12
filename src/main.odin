// M00.03 — Minimal Sokol application shell (Linux/X11).
//
// Opens an 800x600 window titled "Hammer", clears the framebuffer each
// frame, and shuts down cleanly. ESC or closing the window quits.
//
// Test hook: HAMMER_AUTOQUIT_FRAMES=<n> makes the app request quit after
// n frames so the headless Xvfb smoke test can verify startup, frame
// rendering, and shutdown. It is ignored unless set.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

import sapp "sokol:app"
import sg "sokol:gfx"
import sglue "sokol:glue"
import slog "sokol:log"

State :: struct {
	pass_action:     sg.Pass_Action,
	frame_count:     i64,
	autoquit_frames: i64, // 0 = disabled
}

state: State

init :: proc "c" () {
	context = runtime.default_context()

	sg.setup({
		environment = sglue.environment(),
		logger = {func = slog.func},
	})
	state.pass_action.colors[0] = {
		load_action = .CLEAR,
		clear_value = {0.10, 0.12, 0.15, 1.0},
	}
	state.autoquit_frames = autoquit_frames_from_env()

	switch sg.query_backend() {
	case .GLCORE, .GLES3:
		fmt.println(">> using GL backend")
	case .D3D11:
		fmt.println(">> using D3D11 backend")
	case .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR:
		fmt.println(">> using Metal backend")
	case .WGPU:
		fmt.println(">> using WebGPU backend")
	case .VULKAN:
		fmt.println(">> using Vulkan backend")
	case .DUMMY:
		fmt.println(">> using dummy backend")
	}
	fmt.printf(
		">> window initialized: %dx%d px, dpi_scale=%.2f\n",
		sapp.width(),
		sapp.height(),
		sapp.dpi_scale(),
	)
}

frame :: proc "c" () {
	context = runtime.default_context()

	state.frame_count += 1
	sg.begin_pass({action = state.pass_action, swapchain = sglue.swapchain()})
	sg.end_pass()
	sg.commit()

	if state.autoquit_frames > 0 && state.frame_count >= state.autoquit_frames {
		fmt.printf(">> autoquit after %v frames\n", state.frame_count)
		sapp.request_quit()
	}
}

event :: proc "c" (ev: ^sapp.Event) {
	context = runtime.default_context()

	if ev.type == .KEY_DOWN && ev.key_code == .ESCAPE {
		sapp.request_quit()
	}
}

cleanup :: proc "c" () {
	context = runtime.default_context()

	sg.shutdown()
	fmt.printf(">> clean exit after %v frames\n", state.frame_count)
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
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer mem.tracking_allocator_destroy(&track)
	defer report_leaks(&track)

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
}
