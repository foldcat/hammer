# M01.03 — Logical/physical coordinate conversion

**Status:** done (Linux/X11 validated headless incl. a real X11 resize
event; Windows cross-build validated under Wine 11). Real-desktop
dual-monitor mixed-DPI validation remains the recorded follow-up.

This task delivers the logical/physical coordinate conversion
(SPECS.md §18 M01.03, SPECS.md §9.6 "DPI model"): a backend-free
`core/coords` package implementing the rule recorded in
`docs/notes/m00-09-decisions.md` §5 — sapp reports pre-scaled framebuffer
pixels, the editor lays out in logical units and divides by
`dpi_scale`, never applying DPI twice.

## What was built

| Piece | Responsibility |
| ----- | -------------- |
| `src/core/coords/coords.odin` | Distinct `Physical_*`/`Logical_*` size/point structs (f32), conversions in both directions with scale validation, the points ↔ logical px rule (×96/72), and the full points → logical → physical chain. Backend-free (imports `core:` + sibling `errs` only). |
| `tests/unit/coords/coords_test.odin` | 8 tests: identity at 1.0, the §9.6 scale table (100/125/150/200%), logical↔physical round trips at fractional scales, fractional hit-testing, proportion preservation, points conversions, invalid-scale rejection (zero/negative/NaN/±Inf/out-of-range → `.Invalid_Input`, zero result), scale-boundary pinning. |
| `src/main.odin` | `window_metrics` fetches the window service, converts, and logs `physical px / logical units / dpi_scale / backend` at startup (info) and on `.RESIZED` (debug). Invalid scale is reported and falls back to 1.0 (logical == physical). Startup also logs the font points → logical px → physical px chain. |
| `src/platform/platform.odin` | Doc updates only: the window service metrics are framebuffer pixels, converted with `core/coords`. |
| `make.odin` | `tests/unit/coords` added to the core test package list. |

## Design contracts

### The conversion rule (SPECS.md §9.6, decisions §5)

- The backend reports everything in framebuffer pixels: the physical
  window is pre-scaled at creation, `sapp.width()/height()` are the
  framebuffer size, and mouse events arrive in framebuffer pixels
  (docs/notes/m00-05-dpi-ime.md). The editor therefore divides by
  `dpi_scale` for logical layout and multiplies back only when a
  physical pixel count is genuinely needed — DPI is applied exactly
  once.
- Font point sizes convert on the logical side first
  (`points_to_logical_px`: points × 96/72); the scale enters only in
  the logical → physical step. `points_to_physical_px` chains both so
  callers cannot double-apply.

### Scale validation (M01 acceptance: "resize and scale changes do not crash")

- `dpi_scale` is external input. `valid_scale` accepts finite
  `0 < scale <= MAX_SCALE (32)`; anything else (zero, negative, NaN,
  ±Inf, absurd) is an `.Invalid_Input` error, not an assertion — and
  conversions return a zero result plus the error.
- The application layer owns the fallback policy: `window_metrics`
  logs the error and falls back to scale 1.0. The editor degrades to
  a working window instead of crashing.
- Errors are created only on the failure path (`errs` `.None`
  sentinel allocates nothing), so per-frame/per-event conversion
  success costs nothing.

### Type discipline (AGENTS.md §9.3)

`Physical_*` and `Logical_*` are distinct struct types; the two unit
systems cannot be interchanged accidentally, and every crossing point
is an explicit, validating conversion. Integer framebuffer sizes from
the backend are cast to f32 exactly once, at the `Window_Service`
boundary in `window_metrics`.

### Backend-freedom (M01 acceptance)

`core/coords` imports nothing but `core:` packages and the sibling
`errs`; it builds without the Sokol collection and is covered by the
`test` target's no-Sokol rule.

## Validation run (all commands executed this session)

```text
odin test tests/unit/coords -vet -collection:hammer=src   -> 8/8 pass, leak-checked
odin run make.odin -file -- test                          -> 39/39 (errs 6, logging 5,
    lifecycle 5, platform 1, config 14, coords 8), leak-checked
odin run make.odin -file                                 -> debug build, exit 0
xvfb-run -a HAMMER_AUTOQUIT_FRAMES=10 smoke              -> exit 0; log:
    window: 800x600 px, 800x600 logical, dpi_scale=1.00
    font: 12pt = 16 logical px = 16 physical px
Xft.dpi=192 (scale 2.0) smoke                            -> exit 0; log:
    window: 1600x1200 px, 800x600 logical, dpi_scale=2.00
    font: 12pt = 16 logical px = 32 physical px
Real X11 resize under Xvfb (task-owned resizer tool: finds the
    "Hammer" window via _NET_WM_NAME, XResizeWindow 400x300)
    -> exit 0; log: window resized: 400x300 px, 400x300 logical
Real X11 resize at scale 2.0 (resize to 800x600)
    -> window resized: 800x600 px, 400x300 logical, dpi_scale=2.00
release build + smoke                                    -> exit 0
run mode (xvfb-run odin run make.odin -file -- run)      -> exit 0
--config= custom file (13pt)                             -> font: 13pt = 17.333334
    logical px; exit 0
panic path (HAMMER_TEST_PANIC)                           -> exit 132, [PANIC ] logged
Windows: ./build/make windows; Wine 11 smoke             -> exit 0; identical
    window/font lines (os=Windows console logging)
```

The resizer tool was a throwaway X11 helper under `/tmp/opencode`
(not committed), built against the pinned `vendor:x11/xlib` like the
M00.05 spike.

## Traps found (recorded for later tasks)

1. **Xlib protocol errors are asynchronous**: a bad request (e.g.
   `XFetchName` on a window without `WM_NAME`) surfaces as the status
   of the *next* round trip — `XQueryTree` returned `BadRequest` while
   still filling `nchildren`. Resizer and any future native X11 tool
   must descend on the child count and identify windows by
   `_NET_WM_NAME` (`GetWindowProperty`, UTF8_STRING), not by
   `XFetchName`/status codes.
2. **`GetWindowProperty` returns X-allocated storage**: a string
   sliced from the returned buffer must not outlive `XFree(data)`
   (use-after-free showed up as garbled window titles during the
   session).
3. **The pinned Odin has no `odin fmt` command** (dev-2026-11); style
   conformance is by hand against the existing packages.
4. **`math.is_finite` does not exist in the pinned core**; the finite
   check is `!math.is_nan(x) && !math.is_inf(x)`.
5. **The spike's `set-dpi` mode holds the display open by design**
   (run it in the background and kill only that owned process; the
   Xft.dpi resource lives in the root window property).

## Honest status

| Platform  | Status |
| --------- | ------ |
| Linux/X11 | **tested headless**: unit tests, debug/release/run smokes, scale 1.0 and 2.0 (Xft.dpi 192), real X11 resize events at both scales, custom config, panic path, leak-free exit. Real desktop visual check and mixed-DPI handoff (per-monitor RandR tracking is the recorded M05.06/M01 follow-up) are **not validated** — they need a real dual-monitor desktop. |
| Windows   | **cross-build + Wine-validated** (conversion code compiles under `-no-crt`, identical log lines at runtime). Real Windows hardware untested (D-02). |

## Follow-ups (owners)

- M01.04 (input normalization) consumes `to_logical_point` for mouse
  events, which arrive in framebuffer pixels.
- M01.06 (rectangles) lays out in `Logical_*` units and renders via
  `to_physical_*`.
- M05.06 (DPI change invalidation) consumes `points_to_physical_px`
  for font pixel sizes and re-derives layout on scale change; the
  editor-owned per-monitor RandR tracking and mixed-DPI handoff
  validation remain the recorded M00.05 follow-up (needs a real
  dual-monitor desktop).
- The platform `Window_Service` doc comment now names `core/coords`;
  clipboard/IME services remain for M06.04/M06.07.
