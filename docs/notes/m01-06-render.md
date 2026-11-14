# M01.06 — Render basic column/tag/body rectangles

**Status:** done (Linux/X11 validated headless at the pixel level —
including scale 2.0, config-driven color and font-size changes, and a
live resize; Windows cross-build + Wine 11 smoke with the renderer
running, pixel probe not available there by design).

This task delivers the first visible editor shell (SPECS.md §18
M01.06): a window with a tag strip and a body area painted from the
compiled theme, in logical layout units, recomputed every frame so
resizes and scale changes cannot crash. This closes the M01 milestone.

## What was built

| Piece | Responsibility |
| ----- | -------------- |
| `src/core/layout/layout.odin` | Backend-free window geometry: `Rect`, `Window` (frame/tag/body), `window(size, tag_height, pad)` — the frame covers the window, the inner area is inset by `pad` per side, the tag strip is `tag_height` tall, the body fills the rest. Non-finite/negative inputs are `.Invalid_Input` errors; degenerate sizes (zero window, oversized pad/tag) collapse to empty rectangles — never negative, never a crash (M01 acceptance). |
| `src/render.odin` | The application-layer renderer (package main): an embedded GLSL 410 colored-quad shader (the pinned sokol_gfx revision accepts GLSL source on GL backends), a pipeline, and a write-transient vertex buffer. `render_frame` recomputes the layout from the current metrics + `state.scale` + `cfg.Theme`/font size each frame, converts logical → framebuffer → clip coordinates (DPI exactly once), and draws the tag and body rectangles. Failed shader/pipeline creation degrades to no rendering, never a crash. |
| Render probe (test hook) | `HAMMER_RENDER_PROBE[=<frame>]` (Linux/X11 only): reads back single pixels from the default framebuffer with raw GL (the pinned sokol_gfx has no read-back API) and logs the rendered colors at four sample points: tag center, body center, the pad corner, and a fixed point 30 px below the top edge that a larger font covers. |
| `src/main.odin` | Wires the renderer: `render_setup` in init, `render_frame` inside the pass every frame; probe-frame hook. The clear color stays `theme.body_bg` (it covers the border padding). |
| `tests/unit/layout/layout_test.odin` | 6 tests: reference geometry, zero pad/tag, degenerate collapse, invalid-input rejection, and the tag/body partition invariant. |

## Design contracts

### Logical layout, one DPI application (SPECS.md §9.6)

All geometry is computed in logical units from the validated
`state.scale` cache (M01.03/M01.04); `render_frame` maps to
framebuffer pixels and clip coordinates once. At scale 2.0 the same
logical 800x600 layout renders into a 1600x1200 framebuffer
(validated by the probe).

### Layout is recomputed, not cached

The frame-level recompute makes RESIZED and DPI changes structurally
safe: there is no stale layout state to invalidate (M01 acceptance
"resize and scale changes do not crash"; SPECS.md §9.6.4 proportions
fall out of the math). Caching arrives with real rendering cost
(M05).

### Theme-driven

Tag color, body color, and the tag height (font points → logical px →
+2×pad) all come from the compiled config — edits change the rendered
pixels after a rebuild (the M01 acceptance), proven byte-exactly by
the probe, not just by a human on a desktop.

### Backend-freedom (M01 acceptance)

`core/layout` imports `core:math` plus the sibling `coords`/`errs`
packages only; sokol types appear exclusively in the application
layer (`src/render.odin`, `src/main.odin`).

### Raw GL is test-only

The probe's `glReadPixels` block is `when ODIN_OS == .Linux`-guarded
so the Windows cross-build never links libGL; it is a headless
validation hook, not a product readback path.

## Validation run (all commands executed this session)

```text
odin test tests/unit/layout -vet -collection:hammer=src  -> 6/6, leak-checked
odin run make.odin -file -- test                         -> 57/57 (errs 6,
    logging 5, lifecycle 5, platform 1, config 14, coords 8, input 6,
    queue 6, layout 6), leak-checked
Render probe, default config (12pt/13pt example values), scale 1.0:
    render-probe: tag=#262626 body=#161616 corner=#161616 below-tag=#161616
    (exactly the configured theme colors; tag strip ends above y=30)
Render probe, scale 2.0 (Xft.dpi=192, 1600x1200 physical):
    identical logical layout and colors                          -> exit 0
Render probe, custom config (tag #446688, body #112233, 21pt):
    render-probe: tag=#446688 body=#112233 corner=#112233 below-tag=#446688
    (colors AND font-size change the rendered output: the 32-tall tag
    strip now covers y=30)                                       -> exit 0
Live resize during rendering (throwaway X11 resizer, 800x600 -> 400x300,
    probe after the resize): correct colors at the new size, no crash
release build + probe                                          -> exit 0
run mode (xvfb-run odin run make.odin -file -- run)            -> exit 0
Windows cross-build + Wine 11 smoke (renderer running, no probe)
                                                                -> exit 0
panic path (HAMMER_TEST_PANIC)                                 -> exit 132
```

The resizer is a throwaway tool under `/tmp/opencode` (not committed),
reusing the M01.03 window-discovery approach.

## Traps found (recorded for later tasks)

1. **The pinned sokol_gfx is the new-API revision**: no
   `sg_append_buffer`/`sg_update_buffer`/`sg_read_pixels`. CPU vertex
   data goes through `sg_write_buffer_transient` into a buffer created
   with `usage.write_transient = true`, and a transient buffer may be
   written **only until it is first bound** — multiple quads need one
   write with base-element offsets, not per-quad writes.
2. **`sg_apply_bindings` must come after `sg_apply_pipeline`** (the
   classic order is reversed in this revision); the validation layer
   aborts the process otherwise (`VALIDATE_ABND_NO_PIPELINE`).
3. **Shader source for GL backends is `Shader_Desc.vertex_func.source`
   / `fragment_func.source`** (`Shader_Function`), not the classic
   `vs.source` field; GLSL `#version 410`/`430` accepted.
4. **Imports are per-file in Odin**, even within one package: the new
   `render.odin` needed its own import block (and a `package main`
   clause).
5. **Raw GL readback under Xvfb/llvmpipe is exact**: the swapchain
   format is RGBA8 (no FRAMEBUFFER_SRGB), so `glReadPixels` returns
   the configured color bytes unchanged — the probe asserts byte
   equality with theme values.
6. Carried from M01.03: the X11 async-error/`_NET_WM_NAME` window
   discovery (resizer unchanged).

## Honest status

| Platform  | Status |
| --------- | ------ |
| Linux/X11 | **tested headless at the pixel level**: theme colors byte-exact at scale 1.0 and 2.0, font-size-driven tag height, live resize, release/run/panic smokes, leak-free exit. Real-desktop visual check remains the standing M01 follow-up. |
| Windows   | **cross-build + Wine smoke** (renderer initialized and drawing under Wine GL; exit 0). The pixel probe is Linux-only by design; real Windows rendering untested (D-02). |

## Follow-ups (owners)

- M05.01 shader tooling (sokol-shdc pin, Metal/D3D11 variants) replaces
  the embedded GLSL 410 source.
- M05.06 DPI invalidation formalizes the frame-level recompute; M05
  replaces the point-size-derived tag height with glyph metrics and
  paints text (Body_Fg/Tag_Fg unused until then).
- M07.01 (columns/window layout and dragging) builds the real
  multi-window column geometry on `core/layout`.
- The `window_metrics` per-frame call in `render_frame` is the only
  layout/render state; M16 adds persistence of ratios per SPECS §15.4.
