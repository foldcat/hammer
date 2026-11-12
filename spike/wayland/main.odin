// M00.06 — Native Wayland feasibility spike (GLFW-based).
//
// Spike, not the product implementation. The pinned sokol_app has no
// native Wayland backend (Linux = X11 only), so this spike answers: can
// an Odin program get a real native Wayland window today using the
// pinned toolchain's own vendor bindings, and what does that path look
// like? The pinned Odin ships vendor:glfw (GLFW 3.4 bindings); on Linux
// it links the system libglfw3. With the GLFW_PLATFORM_WAYLAND init hint
// the window is a native Wayland client (xdg-shell toplevel, EGL context,
// wl_seat input) — no X server involved.
//
// Modes:
//   probe                  report the GLFW build's supported platforms
//                          and the default platform (no window created)
//   (default)              create a 640x480 window on the platform
//                          selected by HAMMER_GLFW_PLATFORM
//                          (wayland|x11) or GLFW's default, clear the
//                          framebuffer each frame, quit on ESC/close or
//                          after HAMMER_AUTOQUIT_FRAMES frames
//
// Headless test hook: HAMMER_AUTOQUIT_FRAMES=n requests quit after n
// frames so the spike can be smoke-tested without a user. Ignored unless
// set.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"

import glfw "vendor:glfw"

GL_VERSION :: u32(0x1F02)
GL_COLOR_BUFFER_BIT :: u32(0x00004000)

Gl_Procs :: struct {
	clear_color: proc "c" (r, g, b, a: f32),
	clear:       proc "c" (mask: u32),
	get_string:  proc "c" (name: u32) -> ^u8,
}

// load_gl resolves the three GL entry points the spike needs through
// glfwGetProcAddress. rawptr -> proc casts are the canonical GL loader
// pattern; every address is validated against nil first.
load_gl :: proc() -> (procs: Gl_Procs, ok: bool) {
	addr := glfw.GetProcAddress("glClearColor")
	if addr == nil {
		return procs, false
	}
	procs.clear_color = cast(proc "c" (f32, f32, f32, f32)) addr

	addr = glfw.GetProcAddress("glClear")
	if addr == nil {
		return procs, false
	}
	procs.clear = cast(proc "c" (u32)) addr

	addr = glfw.GetProcAddress("glGetString")
	if addr == nil {
		return procs, false
	}
	procs.get_string = cast(proc "c" (u32) -> ^u8) addr

	return procs, true
}

// glfw callbacks run in C; establish an Odin runtime context on entry.
// They only log / request close on the window handle passed in.

error_cb :: proc "c" (code: c.int, description: cstring) {
	context = runtime.default_context()
	fmt.eprintf(">> glfw error %d: %s\n", code, description)
}

close_cb :: proc "c" (window: glfw.WindowHandle) {
	context = runtime.default_context()
	fmt.println(">> close event")
}

key_cb :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	context = runtime.default_context()
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		fmt.println(">> close requested (key=ESC)")
		glfw.SetWindowShouldClose(window, true)
	}
}

fb_size_cb :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	fmt.printf(">> resize: %dx%d\n", width, height)
}

platform_name :: proc(platform: c.int) -> string {
	switch platform {
	case glfw.PLATFORM_WAYLAND:
		return "wayland"
	case glfw.PLATFORM_X11:
		return "x11"
	case glfw.PLATFORM_WIN32:
		return "win32"
	case glfw.PLATFORM_COCOA:
		return "cocoa"
	case glfw.PLATFORM_NULL:
		return "null"
	case:
		return "unknown"
	}
}

// PlatformSupported reports what this GLFW *build* has compiled in; it
// does not need an initialized library. Runtime availability still
// depends on the environment (WAYLAND_DISPLAY / DISPLAY).
Probe_Target :: struct {
	name:     string,
	platform: c.int,
}

PROBE_TARGETS := []Probe_Target {
	{"win32", glfw.PLATFORM_WIN32},
	{"cocoa", glfw.PLATFORM_COCOA},
	{"wayland", glfw.PLATFORM_WAYLAND},
	{"x11", glfw.PLATFORM_X11},
	{"null", glfw.PLATFORM_NULL},
}

run_probe :: proc() -> int {
	fmt.printf(">> glfw version: %s\n", glfw.GetVersionString())
	for target in PROBE_TARGETS {
		supported := "yes" if glfw.PlatformSupported(target.platform) else "no"
		fmt.printf(">> build supports %s: %s\n", target.name, supported)
	}
	if !glfw.Init() {
		fmt.eprintln(">> init failed")
		return 2
	}
	fmt.printf(">> default platform: %s\n", platform_name(glfw.GetPlatform()))
	glfw.Terminate()
	fmt.println(">> exit clean")
	return 0
}

autoquit_frames_from_env :: proc() -> i64 {
	value, found := os.lookup_env("HAMMER_AUTOQUIT_FRAMES", context.temp_allocator)
	if !found {
		return 0
	}
	n, ok := strconv.parse_i64(value)
	if !ok || n < 0 {
		fmt.eprintf(">> invalid HAMMER_AUTOQUIT_FRAMES=%q; ignoring\n", value)
		return 0
	}
	return n
}

requested_platform_from_env :: proc() -> (platform: c.int, set: bool, ok: bool) {
	value, found := os.lookup_env("HAMMER_GLFW_PLATFORM", context.temp_allocator)
	if !found {
		return 0, false, true
	}
	switch value {
	case "wayland":
		return glfw.PLATFORM_WAYLAND, true, true
	case "x11":
		return glfw.PLATFORM_X11, true, true
	case:
		fmt.eprintf(">> invalid HAMMER_GLFW_PLATFORM=%q (want wayland|x11)\n", value)
		return 0, true, false
	}
}

run_window :: proc() -> int {
	autoquit := autoquit_frames_from_env()
	fmt.printf(">> autoquit frames: %d\n", autoquit)

	requested, set, ok := requested_platform_from_env()
	if !ok {
		return 1
	}
	if set {
		fmt.printf(">> platform requested: %s\n", platform_name(requested))
		glfw.InitHint(glfw.PLATFORM, requested)
	} else {
		fmt.println(">> platform requested: default")
	}

	if !glfw.Init() {
		fmt.eprintln(">> init failed")
		return 2
	}
	defer glfw.Terminate()

	platform := glfw.GetPlatform()
	fmt.printf(">> platform: %s\n", platform_name(platform))

	if platform == glfw.PLATFORM_WAYLAND {
		// Both getters return NULL when the active platform is not
		// Wayland; on Wayland they hand out the live wl_display /
		// wl_surface pointers.
		if glfw.GetWaylandDisplay() != nil {
			fmt.println(">> wl_display: ok")
		} else {
			fmt.eprintln(">> wl_display: missing")
		}
	} else {
		fmt.println(">> wl_display: n/a (not wayland)")
	}

	window := glfw.CreateWindow(640, 480, "hammer-wayland-spike", nil, nil)
	if window == nil {
		fmt.eprintln(">> window creation failed")
		return 3
	}
	defer glfw.DestroyWindow(window)

	if platform == glfw.PLATFORM_WAYLAND {
		if glfw.GetWaylandWindow(window) != nil {
			fmt.println(">> wl_surface: ok")
		} else {
			fmt.eprintln(">> wl_surface: missing")
		}
	} else {
		fmt.println(">> wl_surface: n/a (not wayland)")
	}

	glfw.MakeContextCurrent(window)
	glfw.SetKeyCallback(window, key_cb)
	glfw.SetWindowCloseCallback(window, close_cb)
	glfw.SetFramebufferSizeCallback(window, fb_size_cb)

	w, h := glfw.GetFramebufferSize(window)
	fmt.printf(">> framebuffer: %dx%d\n", w, h)

	procs, have_gl := load_gl()
	if have_gl {
		version_ptr := procs.get_string(GL_VERSION)
		version := "unknown" if version_ptr == nil else string(cstring(version_ptr))
		fmt.printf(">> gl version: %s\n", version)
	} else {
		fmt.eprintln(">> gl procs unavailable")
	}

	frames: i64 = 0
	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		if have_gl {
			procs.clear_color(0.10, 0.12, 0.15, 1.0)
			procs.clear(GL_COLOR_BUFFER_BIT)
		}
		glfw.SwapBuffers(window)
		frames += 1
		// Bounded logging: every frame up to 20, then every 10th.
		if frames <= 20 || frames % 10 == 0 {
			fmt.printf(">> frame %d\n", frames)
		}
		if autoquit > 0 && frames >= autoquit {
			fmt.println(">> autoquit")
			break
		}
	}
	fmt.printf(">> frames rendered: %d\n", frames)
	fmt.println(">> exit clean")
	return 0
}

main :: proc() {
	glfw.SetErrorCallback(error_cb)
	if len(os.args) > 1 && os.args[1] == "probe" {
		os.exit(run_probe())
	}
	os.exit(run_window())
}
