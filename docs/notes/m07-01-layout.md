# M07.01 — Columns/window layout and dragging

**Status:** done on Linux/X11. Windows source type-checking passes; the
Windows executable/Wine run is blocked by the pre-existing unsupported
`-ignore-vs-search` compiler flag in `make.odin`.

## Layout model

`src/core/layout/workspace.odin` adds a backend-free retained workspace:

- Up to 8 columns and 16 windows per column, using fixed-capacity storage.
  No layout allocation or destructor is required, and insertion beyond a
  limit returns `.Resource_Limit` without changing the workspace.
- Stable, distinct column/window IDs and positive layout weights.
- A global tag, per-column tags and drag controls, and multiple weighted
  windows with per-window tags, controls, frames, and bodies. Geometry is
  recomputed in logical units, so resize, zoom, and DPI changes preserve
  proportions and never produce negative rectangles.
- Hit-testing that distinguishes global/column/window tags, drag controls,
  window frames, and bodies.

The product starts with two columns and three windows. `src/render.odin`
draws the full workspace and renders the current document in the active
window. Independent per-window buffers, selections, and scrolling remain
M07.02 work; the extra windows are layout shells, not independent views.

## Dragging

A plain primary-button press on a column/window control starts a drag.
Motion updates only transient drag state; the order and weights commit on
release. Losing the held button, focus, or starting another gesture cancels
without changing layout. A release below the five-logical-pixel threshold
is a click and does not mutate layout.

- Moving a window to another column inserts it at the release position.
- Vertical movement can reorder windows or resize an adjacent pair. An
  in-place drag on the first window resizes it against its successor;
  otherwise it resizes the dragged window and its predecessor.
- Horizontal movement has the equivalent column behavior: the first column
  resizes against its successor, and later columns against their predecessor.
- Pair resizing preserves combined weight and keeps each side at least 10%
  of that weight. A single window in a column has no vertical resize pair.

`src/editor.odin` routes body clicks through the active window's actual
geometry, preserving grapheme-safe mouse selection after layout changes.
Existing text editing and transactions are unchanged.

## Tests and validation

`tests/unit/layout/workspace_test.odin` adds 9 tests for IDs/capacity,
geometry partitioning and hit targets, degenerate/invalid input, window
moves/reordering/resizing (including first-window/single-window cases),
column reordering/resizing, click/cancel/outside cancellation, and invalid
weights.

`tests/integration/layout/x11_harness.py` drives real X11 pointer events
through first-window resizing, cross-column moves, same-column reordering,
adjacent window/column resizing, rendering changes, and clean shutdown.
`make.odin` exposes it as `layout-test`. Existing mouse-selection coordinates
in the typing harness were moved below the new global and column tags; its
selection-color check also exposed and prevented reuse of the selection
color for column controls.

Commands run in this session:

```text
odin test tests/unit/layout -vet -collection:hammer=src
    -> 15/15 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- layout-test --no-config
    -> all six real X11 drag checks passed
odin run make.odin -file -- typing-test --no-config
    -> all existing typing/mouse/clipboard/zoom/save/close checks passed
odin run make.odin -file -- test
    -> all 333 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 38 native text tests and four visual golden hashes passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=6 HAMMER_RENDER_PROBE=5 HAMMER_LOG= ... ./build/hammer
    -> exact theme pixels at scale 1, clean shutdown
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=6 HAMMER_RENDER_PROBE=5 HAMMER_TEST_DPI_SCALES=2 HAMMER_LOG= ... ./build/hammer
    -> exact theme pixels at scale 2, clean shutdown
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
odin run make.odin -file -- windows --no-config
    -> blocked before compilation: Odin dev-2026-11 reports
       "Unknown flag: 'ignore-vs-search'"
```

No native Windows run, Windows/Wine run, or real-desktop visual review was
performed. The Windows build failure is pre-existing build tooling, not a
layout diagnostic; it remains visible for a separate build-maintenance fix.

## Next task

M07.02 should map stable window IDs to independent views, sharing buffer
text/history where appropriate while keeping selection and viewport state
per view. It should also replace the fixed demonstration window set with
product-level window creation and close behavior that preserves dirty-file
safety.
