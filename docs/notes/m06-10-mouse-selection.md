# M06.10 — Mouse selection of text

**Status:** done on Linux/X11. Primary-button click places the caret, drag selects
text, and release preserves the selection. The Windows cross-build still has no
text renderer or product text hit testing.

## Product behavior

`src/editor.odin` consumes normalized pointer events before keyboard action
resolution. A plain primary-button press starts a selection, motion extends it,
and release finishes it. Shift+primary extends from the existing anchor. Ctrl,
Alt, Super, and non-primary presses are left for their later command/chord tasks.
Typing-group state ends on mouse selection. Losing the held button, focus, or
window availability cancels the active drag without changing the selection or
document.

`src/text_hit_linux.odin` maps logical pointer coordinates through the same body
geometry, font, pixel size, line height, tab expansion, and visible-line shaping
used by the renderer. `shaping.hit_test` supplies grapheme-safe offsets and bidi
caret affinity. The new `shaping.tab_source_offset` maps display carets back to
source bytes and chooses the nearest source edge within an expanded tab.

Hit testing reads and shapes only the selected visible line, using the existing
64 KiB shaping budget plus 4 KiB lookahead. Drag positions outside the body clamp
to the visible lines. Scrolling and off-screen hit testing are not part of this
slice. Non-Linux hit testing returns no result until those platforms gain text
rendering.

`src/render.odin` now shares its window geometry calculation with hit testing.
Selection rendering itself was already present from M06.09.

## Tests

`tests/integration/textdeps/tabs_test.odin` covers source/display offset round
trips, hits inside expanded tabs, and invalid offsets. Existing native shaping
tests cover grapheme, bidi, ligature, and fractional-DPI hit testing.

`tests/integration/typing/x11_harness.py` uses real X11 pointer motion and button
events to drag across two rendered lines. It verifies the selection color appears,
remains after release, and disappears after a subsequent primary click. It also
checks that undo still restores the original document.

## Validation

```text
odin run make.odin -file
    -> Linux debug product build passed
odin run make.odin -file -- text-test
    -> all 28 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- typing-test
    -> all X11 typing/rendering and mouse-selection checks passed
odin run make.odin -file -- test
    -> all 300 core unit tests passed, allocator tracking clean
odin run make.odin -file -- windows
    -> Windows cross-build passed
xvfb-run -a env WINEDEBUG=-all HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine ./build/hammer.exe
    -> Windows/Wine lifecycle smoke passed; native font support remains unavailable
```

## Limits and next task

- Product mouse selection was exercised only on Linux/X11 at scale 1. Unicode and
  bidi behavior is covered by native shaping tests, not by the product harness.
- No scrolling, Acme mouse chords, middle-button execution/paste, or Windows
  product hit testing is claimed.
- M06.11 should connect Ctrl+C and Ctrl+V to the native clipboard service and
  revision/selection-validated paste path, with external-application interop tests.
