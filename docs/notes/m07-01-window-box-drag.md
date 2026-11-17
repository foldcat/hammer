# Window box drag: predictable resize vs swap

**Status:** done on Linux/X11; core layout logic, no platform-specific code.
This was a requested fix and does not replace the active M07.04 task.

## Problem

Dragging a window's control box (the small square in its tag) was finicky:

- Dragging the bottom-left window's box **up** did nothing. The release point
  landed outside the dragged window's own frame, and `end_window_drag` guarded
  the resize path with `contains(source window frame, point)`, so it bailed out.
- Whether a drag swapped windows depended on the **frame midpoint**, which sits
  far below the box, so a short drag unexpectedly swapped and a longer drag did
  nothing. The result "sometimes" swapped.

## Fix

`src/core/layout/workspace.odin`:

- Removed the `contains(...frame, point)` guard from the same-column resize path.
  A box can legitimately be dragged out of its own window (up into the neighbor's
  area) to resize, so the release point no longer has to sit inside the source
  frame.
- Split the insertion decision into two functions:
  - `window_insertion` (frame midpoint) is kept for **cross-column** moves, where
    dropping in a window's upper/lower half inserts before/after it.
  - `window_box_insertion` (control-box top) is used for **same-column** drags.
    A box dragged past another window's box swaps the two; any shorter drag
    resizes the dragged window against its neighbor.

This matches Acme: dragging a window's box below another window's box swaps
them; otherwise the pair is resized. The resize direction (first window against
its successor, others against their predecessor) is unchanged.

## Regression coverage

`tests/unit/layout/workspace_test.odin` adds two tests:

- `test_window_drag_up_into_neighbor_resizes` — dragging the bottom window's box
  up into the neighbor's area (but below the neighbor's box) grows the bottom
  window and does not reorder.
- `test_window_drag_down_past_box_swaps` — dropping the top window's box just
  below the bottom window's box swaps them (the old midpoint logic treated this
  region as a resize).

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
odin test tests/unit/layout -vet -collection:hammer=src
    -> 17/17 passed (15 existing + 2 new)
odin run make.odin -file -- test
    -> all core unit tests passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-view checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
```

A real X11 drag confirmed the product behavior: dragging the bottom window's box
up grows it (weight 1.4874, logged) instead of no-op/swapping, and dragging the
top window's box down past the other box swaps the two.

## Not validated / pre-existing

Native Windows/Wine runtime (cross-build type-checks only).

`odin run make.odin -file -- layout-test --no-config` still fails at
"moving the active window did not change rendered pixels". This is the same
pre-existing rendering-check failure documented in
`docs/notes/m07-03-global-tag-clip.md`; the drag steps themselves (in-place
resize and cross-column move) pass, so the box-drag fix does not affect it.
