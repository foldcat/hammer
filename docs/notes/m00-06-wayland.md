# M00.06 — Spike native Wayland feasibility for the chosen backend

**Status:** done (Linux, validated headless via weston/Xvfb). Windows remains
deferred (see below); nothing is claimed for it.

This session revised the 2026-11-12 deferral decision: instead of closing
M00.06 as documentation only, the Wayland spike was actually performed.
Windows was still deferred, for a toolchain reason: no Wine exists on this
machine and building it requires a 32-bit multilib toolchain the owner
chose not to compile this session (hours). The Windows halves of
M00.03–M00.08 stay deferred and must be recorded as such in the M00.09
compatibility inventory.

## What was built

`spike/wayland/` contains a GLFW-based native Wayland window spike plus a
headless demo harness:

- `main.odin` — one binary, two modes:
  - `probe` — reports the GLFW version string, which platforms this GLFW
    build has compiled in (`glfwPlatformSupported`, no init needed), and
    the default platform selected at init.
  - (default) — creates a 640x480 window on the platform selected by
    `HAMMER_GLFW_PLATFORM` (`wayland`|`x11`) or GLFW's default, reports
    the active platform, the live `wl_display`/`wl_surface` pointers
    (`glfwGetWaylandDisplay`/`glfwGetWaylandWindow`, non-NULL on Wayland),
    the framebuffer size and GL version, then runs a clear/swap loop with
    ESC/close handling and a `HAMMER_AUTOQUIT_FRAMES=n` quit hook.
- `demo.sh` — headless end-to-end: negative path (no compositor), native
  Wayland under weston, X11 contrast under Xvfb, and the XWayland product
  path (see below). `make.odin` gained a `wayland-spike` target.
- System additions (approved): `dev-libs/weston` (`headless xwayland` USE)
  and `media-libs/glfw` (`wayland X`) via
  `/etc/portage/package.use/hammer`. Weston is the _reference_ compositor;
  nothing here claims validation on sway/labwc/KDE/etc.

This is spike code, not the product implementation. The product path
remains sokol/X11 (M01+); nothing in this spike changes that.

## Finding 1 — the pinned sokol has no native Wayland backend (verified)

The pinned `sokol_app.h` (sokol C commit `93aa187`, bindings `ae94aa5`)
has a Linux backend that is X11 only (GLX, or EGL-on-X11 with
`SOKOL_FORCE_EGL`); there is no Wayland backend in this revision. No
`wl_*` protocol code exists in the header. On a Wayland session, any
pinned-sokol application therefore runs through XWayland.

## Finding 2 — the XWayland product path works (verified)

`build/hammer` (sokol X11 + GLX, from M00.03) run against weston 14's
Xwayland (`weston --backend=headless-backend.so --xwayland`, display
number discovered from the weston log): window initialized 800x600, GL
backend active, 5 frames rendered, clean exit 0. GLX under Xwayland goes
through Xwayland's glamor; it worked with Mesa's software rendering.

Caveat: under Xwayland the `Xft.dpi` lookup fails exactly as under Xvfb
(`LINUX_X11_QUERY_SYSTEM_DPI_FAILED` warning, defaults to 96.0). A real
desktop session sets it via xrdb/portals; this is the same warning M00.05
already documented, not a new Wayland-specific defect.

## Finding 3 — native Wayland is feasible today via pinned `vendor:glfw` (verified)

The pinned Odin toolchain ships `vendor:glfw` (GLFW 3.4 bindings,
including the `GLFW_PLATFORM_WAYLAND` init hint and the weak-linked
`glfwGetWaylandDisplay`/`glfwGetWaylandWindow` getters); on Linux it links
the system libglfw3. Verified headless (weston's `x11-backend.so` nested
in Xvfb — a full compositor with a seat and a GL renderer, but no
physical display):

- **Platform auto-selection**: with `WAYLAND_DISPLAY` set and `DISPLAY`
  unset, GLFW picks the Wayland platform on its own (`glfwGetPlatform`
  reports `wayland`). The `probe` mode confirms the build supports
  wayland, x11, and null.
- **Real protocol objects**: `glfwGetWaylandDisplay` /
  `glfwGetWaylandWindow` return live `wl_display`/`wl_surface` pointers
  (both non-NULL, asserted by the harness).
- **EGL context**: created successfully (Mesa 26.1.8, GL 4.6
  compatibility profile via software rendering). The `libEGL warning:
failed to get driver name / failed to create dri2 screen` lines are
  Mesa's initial hardware-probe noise before it falls back to software;
  they do not affect the context.
- **Frame loop**: clear/swap per frame, frame callbacks delivered, 5
  frames rendered, autoquit, clean exit 0.
- **X11 contrast**: the same binary with `HAMMER_GLFW_PLATFORM=x11` under
  Xvfb (GLX) produces the same results — proving the platform hint really
  switches the windowing backend, and the spike's GL/callback code is
  platform-neutral.
- **Negative path**: `HAMMER_GLFW_PLATFORM=wayland` with no compositor in
  the environment fails cleanly at init (platform unavailable), exit 2.

Nested-weston protocol dump notes (for later milestones): weston 14's
x11 backend advertises `wl_seat`, `zwp_linux_dmabuf_v1`,
`zwp_text_input_manager_v1`/`zwp_input_method_v1` (v1, not v3), but no
`zxdg_decoration_manager_v1` — GLFW therefore falls back to libdecor
(GTK plugin) for client-side decorations, which works when a seat exists.

## Finding 4 — headless-compositor trap: weston headless has no `wl_seat`

`weston --backend=headless-backend.so` creates no input devices, so it
advertises **no `wl_seat` global**. The pinned GLFW 3.4 then segfaults
inside `glfwInit` (`wl_proxy_get_version` dereferencing the NULL seat
binding; backtrace captured, plus GDK seat assertions from the
libdecor-gtk plugin that loads alongside). This is a pinned-GLFW
limitation on seat-less compositors, not an Odin bug.

Consequence for any future headless CI: GLFW-on-Wayland tests need a
compositor that provides a seat; weston's x11 backend nested in Xvfb (as
used here) works, while the headless backend does not. A raw-protocol
client (no GLFW) would likely be fine without a seat; GLFW is not.

## Finding 5 — input on Wayland is not runtime-validated headless

The nested compositor has a real seat (fed from Xvfb), but this machine
has no headless input-injection tool (no xdotool), so no key/mouse event
was delivered through `wl_seat` to the spike. The key/close/
framebuffer-size callbacks are wired and compiled, and the close/frames
paths are validated; the ESC-close path needs a real desktop or an
injection tool. GLFW's callback plumbing is platform-neutral and was
exercised on the X11 contrast run. This is recorded as implemented-but-
not-validated, per SPECS.md §19 honesty rules.

IME on Wayland: GLFW 3.4 implements no text-input protocol on Wayland
(no `zwp_text_input_v3`/input-method client support), and XIM-style
composition does not exist on Wayland. If a GLFW windowing layer were
ever productized, M06.07 (IME preedit/commit) would need work outside
GLFW. Noted for M00.09.

## Implications for later milestones

- **Product path unchanged**: sokol/X11 via XWayland inside Wayland
  sessions (Finding 2). No sokol change, no GLFW in the product.
- **Native Wayland options**, all future decisions, to be recorded in
  M00.09: (a) a sokol Wayland backend — none exists at the pinned
  revision; (b) GLFW windowing + sokol_gfx over EGL, using
  `glfwGetWaylandDisplay` + `eglGetPlatformDisplay` — GLFW exposes the
  `wl_display`, so this is architecturally possible; (c) `vendor:sdl3`
  (SDL3 has a native Wayland video driver) — untested here.
- **M00.09 inventory additions**: Wayland clipboard (native
  `wl_data_device`; M00.04 covered X11 only; no shelling to `wl-copy`),
  Wayland DPI/IME gaps, the headless-CI seat trap, and the deferred
  Windows halves of M00.03–M00.08.
- **Revisit point**: when a Tier-1 "Linux on Wayland" decision is due
  (SPECS.md §1.2), re-run this spike against sway/labwc and with an input
  injection tool.

## Validation

- `odin run make.odin -file -- wayland-spike` — builds `build/wayland_spike`,
  `-vet` clean. Release variant (`-o:speed -no-bounds-check`) compiles too.
- `./spike/wayland/demo.sh build/wayland_spike build/hammer` — ALL OK:
  negative path, native Wayland window + EGL under nested weston, X11
  contrast under Xvfb, pinned-sokol hammer under weston Xwayland.
- Backtrace for Finding 4 captured with gdb; protocol traffic inspected
  with `WAYLAND_DEBUG=1`.

## Not validated

- Real-world compositors (sway, labwc, KDE, GNOME) — weston only.
- Wayland input events end-to-end (Finding 5).
- Wayland clipboard, DPI-change events, per-monitor scales, IME.
- Windows (deferred, see top).
