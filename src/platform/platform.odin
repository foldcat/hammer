// Package platform: abstract platform service interfaces.
//
// The application layer (Sokol on X11 today) implements these; core
// code depends only on these interfaces, never on the windowing
// backend. This is the boundary SPECS.md §3.2 requires ("no
// dependency-specific code leaks into the core") and the M01
// acceptance checks.
//
// The surface grows milestone by milestone, each time with a real
// consumer:
//
// - M01.01: window metrics (consumed by startup/resize diagnostics;
//   M01.03 builds logical/physical coordinate conversion on top).
// - M06.04: the clipboard service.
// - M06.07: IME preedit/commit.
//
// Services are plain proc-pointer structs: data-oriented, no vtables,
// no hidden allocation (AGENTS.md §9.2). A `user: rawptr` is threaded
// through so one implementation can serve several instances (e.g. one
// per window).
package platform

// Window_Service exposes the physical window metrics the editor needs
// for layout. All sizes are framebuffer pixels; M01.03 defines the
// conversion to logical coordinates (divide by dpi_scale).
Window_Service :: struct {
	// framebuffer_size returns the current framebuffer size in
	// physical pixels.
	framebuffer_size: proc(user: rawptr) -> (width, height: i32),
	// dpi_scale returns the current physical/logical scale factor.
	dpi_scale: proc(user: rawptr) -> f32,
}

// Services is the set of platform capabilities the application layer
// implements for the core. Currently only the window service exists;
// clipboard and IME are added by their milestones.
Services :: struct {
	// user is passed as the first argument to every proc below.
	user: rawptr,
	window: Window_Service,
}
