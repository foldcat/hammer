# M06.14 — Text zoom keybinds and Ctrl+mouse-wheel

**Status:** done on Linux/X11 with real product rendering, selection/caret, and
atlas-lifetime validation. Windows-target core checks pass; Windows visual zoom
remains unvalidated because the full product build stops before source compilation.

## Zoom policy

`src/core/keybind` resolves:

- Ctrl+=, Ctrl+Shift+= (Ctrl++), and Ctrl+keypad-plus to zoom in.
- Ctrl+- and Ctrl+keypad-minus to zoom out.
- Ctrl+0 and Ctrl+keypad-zero to restore the compiled `font_size_points`.
- Exact Ctrl+vertical-wheel up/down to zoom in/out. Plain wheel, horizontal-only,
  zero, non-finite, and additional-modifier scroll events are not zoom actions.

`src/core/dpi.next_zoom_points` applies one-point steps, clamps to 4–72 pt, and
validates current/baseline values and the action. Limits and reset no-ops do not
advance DPI generations or rebuild caches. Zoom is runtime view state: it does not
change the compiled configuration, buffer revision, dirty state, undo history,
selection, or caret.

## Rendering and cache lifecycle

`state.dpi.points` is initialized from the compiled configuration and remains the
effective size across ordinary DPI polls. `window_metrics` accepts a requested zoom
size, updates the existing DPI generation, and invalidates glyphs whenever the
rounded physical size changes from either zoom or monitor scale.

The same effective point size now drives:

- glyph rasterization and cache keys (`src/glyph_cache.odin`);
- visible text shaping and line height (`src/text_render_linux.odin`);
- mouse hit-testing (`src/text_hit_linux.odin`);
- the tag/body layout split (`src/render.odin`).

Zoom reuses `glyphcache.reset` and `GPU_Glyph_Atlas`; it does not allocate a new
permanent atlas per level. Existing dirty pages are reuploaded and prewarmed.

## Input adapter fixes

Real X11 validation exposed two boundary issues that unit actions alone missed:

1. XIM delivered printable commits such as Ctrl+= without modifier facts, replacing
   the selection before the zoom key-down. `platform.IME_Event` now carries
   `input.Modifiers`; `x11ime` translates `XKeyEvent.state`, and product dispatch
   passes them to `input.Commit_Text`. The existing resolver therefore suppresses
   command commits while preserving AltGr text.
2. Sokol reports wheel-up as positive `scroll_y`, while normalized `input.Scroll`
   defines positive as down. The Sokol adapter now negates vertical wheel delta at
   that boundary, so the backend-free resolver remains conventional.

Temporary selection diagnostics used during debugging were removed.

## Regression coverage

DPI tests cover step/reset behavior, fractional clamps, both limits, invalid values,
and invalid actions. Keybind defaults cover every keyboard binding and repeat
policy; event tests cover wheel direction, exact modifiers, horizontal/zero deltas,
and non-finite input.

`tests/integration/typing/x11_harness.py` performs eight real zoom transitions. It
checks Ctrl+=/Ctrl+- and Ctrl+Shift+=/Ctrl+0 round trips, Ctrl+wheel up/down, inert
plain wheel, changed layout pixels, retained selection highlight and exact copied
bytes, and a post-zoom insertion at the original collapsed caret. After shutdown it
verifies at least eight cache rebuilds and a constant atlas-page count across those
rebuilds. Earlier fallback-font discovery may grow the atlas before zoom begins;
that unrelated growth is not mistaken for a zoom leak.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin test tests/unit/dpi -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 6 DPI tests passed, allocator tracking clean
odin test tests/unit/keybind -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 14 keybind tests passed, allocator tracking clean
odin run make.odin -file -- typing-test
    -> all Linux product typing/clipboard/autopair/newline/zoom checks passed
    -> eight zoom cache rebuilds retained two pages; selection/caret bytes preserved
odin run make.odin -file -- test
    -> all 321 core unit tests passed, allocator tracking clean
odin run make.odin -file -- autopair-test
    -> enabled and disabled autopair product regressions passed
odin run make.odin -file -- ime-test
    -> native X11 IME integration test passed with modifier propagation
odin check src/core/dpi -no-entry-point -vet -target:windows_amd64
odin check src/core/keybind -no-entry-point -vet -target:windows_amd64
odin check src/core/input -no-entry-point -vet -target:windows_amd64
    -> all Windows-target core checks passed
odin run make.odin -file -- windows
    -> blocked before source compilation: Unknown flag: 'ignore-vs-search'
```

The pinned compiler has no `odin fmt` command and no `odinfmt` executable is
installed. Formatting was reviewed manually.

## Limits and next task

- Windows visual zoom, Wayland, and touchpad-specific physical gestures were not
  exercised. Min/max zoom behavior is unit-tested but not driven through 68 real
  product key events.
- Next is M06.15: open `hammer filename`, implement Ctrl+S through safe save, and
  verify failed saves preserve dirty state and lossy-close protection.
