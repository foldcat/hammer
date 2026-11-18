# M07.10 — Viewport scrolling and scrollbar rendering/interaction

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Per-view viewport origins

Each `core/view.View` now owns a logical `first_line`, a visual `first_row`
within that line, and fractional wheel remainder in addition to its existing
horizontal offset. Origins are clamped to the document and to the current wrapped
row count before rendering or hit-testing. Look resets both origin components.
The origin remains view-local and is not persisted; project session restoration
is M16 work.

Wheel/touchpad input scrolls three visual rows per notch, accumulating fractional
input and limiting each event to 64 rows. Horizontal scrolling and Ctrl+wheel
zoom retain their existing behavior. Soft wrapping can scroll through individual
rows of one logical line; truncate mode advances one row per logical line.

`src/text_rows_native.odin` measures a bounded visible line with the same font,
width, and wrap rules as the renderer. `text_render_native.odin` and
`text_hit_native.odin` skip the same initial visual rows, including selection,
caret, IME, and row-local source-byte hit mapping. Non-Linux/Windows stubs retain
matching signatures.

## Scrollbar geometry and interaction

`src/core/scroll/scroll.odin` reserves a 12-logical-unit track at the left of each
body and computes a bounded proportional thumb with an 8-unit minimum height.
Thumb size uses logical line count and visible rows; local wrapped-row progress
contributes to its position. Geometry is recomputed from current body and font
metrics after resize/DPI changes.

Button 1 scrolls toward the document start and button 3 toward the end. Both act
on press and repeat while held, with a bounded 40–260 ms interval determined by
pointer height. Button 2 jumps to an absolute logical line, as does a press
outside the thumb with any button. Dragging any button uses absolute positioning
to follow the pointer and disables timed repeat. Pointer capture continues
outside the track, clamping vertical positions to its endpoints. A dedicated
state machine tracks the window, held button, track, and repeat deadline. Losing
held-button state, starting another pointer gesture, focus loss, window removal,
and shutdown cancel repetition. Each frame performs at most one repeat step.
Scrollbar input does not select text, activate another window, or enter
Execute/Look chords.

`src/render.odin` paints the track with the configured tag background and the
thumb with dark gray `#525252`, then clips text to the content rectangle to their
right. Existing X11 harness pointer coordinates were adjusted for that reserved
strip without weakening their text or command assertions.

## Regression coverage

Six core scroll tests cover body splitting, thumb bounds/resize behavior,
button mapping, absolute positioning, drag-follows-pointer behavior, repeat
rates, invalid geometry, and lost capture. View tests pin independent wrapped-row
and fractional-wheel state.

`tests/integration/scroll/x11_harness.py`, exposed as `scroll-test`, builds soft
and truncate binaries and uses isolated files plus real X11 input. In each mode
it checks:

- Distinct dark-gray track/thumb rendering.
- Vertical wheel advancement, visual change, and exact reverse restoration.
- Immediate and held button-3 scrolling, including a wrapped local row.
- Button-1 reverse scrolling, non-thumb jump clicks, direct drag-to-end
  positioning outside the track, button-2 absolute jumps, and thumb movement.
- Exact source-byte insertion after scrolled hit-testing.
- Continued scrolling after a real window resize.

The existing wrap, typing, mouse, tag, view, Look, directory, layout, and
integrated compatibility harnesses all pass with the new body geometry.

## Validation

```text
odin test tests/unit/scroll -vet -collection:hammer=src
    -> all 6 tests passed, allocator tracking clean
odin test tests/unit/view -vet -collection:hammer=src
    -> all 7 tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- scroll-test
    -> all 12 soft/truncate X11 checks passed, including non-thumb jumps and outside-track drags
odin run make.odin -file -- wrap-test
    -> all 7 soft/truncate X11 checks passed
odin run make.odin -file -- test
    -> all 369 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 40 native text tests and 4 visual golden hashes passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord and ten cut/undo stress checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin run make.odin -file -- view-test --no-config
    -> all independent-buffer/view checks passed
odin run make.odin -file -- look-test --no-config
    -> all Look/file-opening checks passed
odin run make.odin -file -- directory-test --no-config
    -> all directory/error checks passed
odin run make.odin -file -- layout-test --no-config
    -> all layout checks passed
odin run make.odin -file -- compatibility-test --no-config
    -> all 7 compatibility stages passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
git diff --check
    -> passed
```

No native Windows/Wine run, real-desktop review, or runtime DPI transition test
was performed. Thumb proportions use logical lines rather than measuring every
wrapped row in the document, avoiding whole-document shaping on each frame.

## Next task

M07.11 should add a per-view line-number gutter without disturbing the new
scrollbar/content rectangles or shared visual-row hit-testing.
