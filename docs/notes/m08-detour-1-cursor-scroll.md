# M08.detour-1 — Reveal a truncated caret after Right motion

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Behavior

A successful grapheme-Right action in a truncate body now reveals the caret when
it crosses the visible right edge. The view advances its existing horizontal
offset just enough to place the caret inside the text viewport. A caret already
in view, or one behind the current left edge, does not change the offset. Soft
wrap remains at horizontal offset zero, and wheel scrolling is unchanged.

The caret coordinate uses the same body font, DPI scale, tab expansion, Unicode
shaping, and selection affinity as rendering. Work remains bounded by the
existing visible-line shaping budget; a caret outside that shaped prefix does
not trigger scrolling.

## Implementation

`src/core/scroll/scroll.odin` adds the pure right-edge offset calculation,
including finite-value and maximum-offset bounds. `src/text_rows_native.odin`
measures the active line's caret x coordinate; the non-native stub retains the
same API. `src/scroll_ui.odin` obtains the current body geometry and applies the
calculation, and `src/editor.odin` invokes it after successful Right movement.

## Regression coverage

`tests/unit/scroll/scroll_test.odin` covers visible carets, crossing the right
edge, preserving a larger manual offset, maximum-offset clamping, and invalid
viewport width.

`tests/integration/wrap/x11_harness.py` moves Right through a Unicode truncated
line, verifies a positive offset and changed rendering, then inserts and saves
at the exact long-line end. Existing soft-wrap, horizontal wheel, hit-testing,
viewport, scrollbar, and typing checks remain covered.

## Validation

```text
odin test tests/unit/scroll -vet -collection:hammer=src
    -> 7/7 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- wrap-test
    -> all 8 soft/truncate X11 checks passed, including Right caret reveal
odin run make.odin -file -- test
    -> all 437 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 40 native text tests and 4 visual golden hashes passed
odin run make.odin -file -- scroll-test
    -> all 17 soft/truncate viewport/scrollbar/DPI checks passed
odin run make.odin -file -- typing-test --no-config
    -> all X11 typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
git diff --check
    -> passed
```

No native Windows/Wine run or real-desktop review was performed. Leftward and
vertical caret-driven scrolling were not added by this task.

## Next task

M09.01: implement process spawning and explicit handle ownership, including
bounded lifecycle cleanup and isolated tests.
