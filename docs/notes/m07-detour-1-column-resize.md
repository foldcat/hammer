# M07.detour-1 — Column control horizontal resizing

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Problem and behavior

The pink control in a column tag used the release position to choose between
resizing and reordering. A drag released inside the original column resized an
adjacent pair, but crossing the column boundary moved the entire column. This
made ordinary horizontal resizing inconsistent.

`src/core/layout/workspace.odin` now gives column-control drags one outcome:
horizontal delta resizes the dragged column against its successor for the first
column, or against its predecessor for later columns. Release position no
longer invokes column movement and no longer has to remain inside the source
frame. Column order and window ownership therefore remain unchanged even when
the pointer crosses another column. Existing combined-weight preservation and
10% minimum pair weights still apply, and resizing still commits on release.

Window-control dragging is unchanged: window boxes can still reorder windows
or move them between columns.

## Regression coverage

`tests/unit/layout/workspace_test.odin` replaces the column-reordering
expectation with a crossing-boundary regression. It checks column IDs, window
ownership, both weights, and their preserved sum, then performs an ordinary
follow-up resize using the newly arranged control position.

`tests/integration/layout/x11_harness.py` drives the same crossing gesture with
real X11 pointer events. It verifies that column 2 remains at index 1 while its
weight grows, then drags its relocated pink control and verifies that the
weight shrinks without reordering.

## Validation

```text
odin test tests/unit/layout -vet -collection:hammer=src
    -> 17/17 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- layout-test --no-config
    -> all six real X11 drag checks passed, including boundary crossing
odin run make.odin -file -- test
    -> all 353 core unit tests passed, allocator tracking clean
odin run make.odin -file -- view-test --no-config
    -> all four independent-view checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed.

## Next task

M07.05 should implement modifier-assisted gestures without starting primary
selection or text dragging, including cancellation, AltGr text-input
protection, keyboard alternatives, and X11 product coverage.
