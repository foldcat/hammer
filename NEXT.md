# What to do?

Complete the M00 section, one task per session, in order. Write your
documentations in `/docs`.

## Current task: M00.07 — Spike PTY (Linux) and asynchronous process output

ConPTY deferred. Details to be pinned at session start (see the M00.03–
M00.06 docs for the spike format; keep the report honest about what is
validated versus assumed).

## M00.06 done (2026-11-12 session)

The Wayland deferral was reversed: the native Wayland feasibility spike
was actually performed. `spike/wayland/` (GLFW-based, `vendor:glfw` +
system libglfw3) plus `docs/m00-06-wayland.md`:

- Pinned sokol has no native Wayland backend; the product path is XWayland,
  verified: hammer runs cleanly under weston + Xwayland, headless.
- A native Wayland window (xdg-shell, EGL, frame loop) works today via the
  pinned toolchain's `vendor:glfw`; validated headless under weston nested
  in Xvfb, including the negative path (no compositor) and an X11 contrast.
- Known traps recorded: weston's headless backend has no `wl_seat` and
  crashes pinned GLFW 3.4; Wayland input is implemented but not validated
  headless (no injection tool); GLFW has no Wayland IME support.
- Windows stays deferred: no Wine and no 32-bit multilib toolchain on this
  machine (building it would take hours; owner decision). The Windows
  halves of M00.03–M00.08 must be recorded as deferred in the M00.09
  compatibility inventory.

## Next tasks after M00.07

- M00.08 Minimal FUSE deployment proof (needs an approved isolated mount).
- M00.09 Record architecture decisions and compatibility inventory.
