# M08.detour-2 — Modifier-key chording (Ctrl=Cut, Alt=Paste)

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Problem and behavior

M07.05 already mapped modifier+click for the single-gesture actions — Ctrl+
primary = Execute (button 2) and Alt+primary = Look (button 3) — so running
commands no longer needs a middle button. The multi-button chords remained
mouse-only: Cut (`1-2`), Paste (`1-3`), and their reversals (Snarf) required a
physical middle or right button, which laptops lack.

A primary selection gesture now accepts Ctrl and Alt as the chord's second
button:

- Hold button 1 (select), then tap **Ctrl** → **Cut** (the `1-2` chord).
- Hold button 1 (select), then tap **Alt** → **Paste** (the `1-3` chord).
- Tapping the opposite key reverses a pending chord exactly like the physical
  button: Ctrl then Alt is Snarf (undo cut); Alt then Ctrl undoes a paste.

This reuses the existing chord semantics, the shared transaction/clipboard
safety path, and the reversal logic unchanged — it only supplies the second
button from a modifier key instead of a second mouse button. Releasing the
modifier key is a no-op; the gesture still completes on the primary-button
release, so `Select_Finish` and lost-capture/cancellation behavior are
unchanged. Shift and Super do not chord. A modifier key alone (with no button
held) never starts a gesture, and modifier keys in Execute/Look mode still
cancel the gesture as before.

## Implementation

`src/core/mouse/mouse.odin` factors the chord branch of `down` into
`chord_button`, shared by physical button presses and a new `modifier_down`
entry point. `modifier_down` applies a virtual button press only while a Select
gesture is held (Ctrl→middle, Alt→right) and returns nothing otherwise.

`src/mouse_ui.odin` adds `modifier_chord_button` (key→button) and
`editor_modifier_chord`, which consumes a non-repeat Ctrl/Alt key press during
a held Select gesture by dispatching `mouse.modifier_down`, and swallows the
matching key release so it does not cancel the gesture.

`src/editor.odin` routes `Key_Down`/`Key_Up` through `editor_modifier_chord`
before the existing cancel-on-non-pointer-input path. Every other key, and
every modifier key outside a held Select gesture, still cancels as before.

The `2-1` execute-with-argument chord has no modifier equivalent because it
uses the same physical button for both button 1 and button 2; it still requires
a physical middle button and is documented as out of scope here.

## Regression coverage

`tests/unit/mouse/mouse_test.odin` gains four tests covering modifier-driven Cut
and its Snarf reversal, Paste and its reversal, no-op when no button is held,
and no-op in Execute/Look modes.

`tests/integration/mouse/x11_harness.py` gains one scenario that selects a word
with a held button 1, taps Ctrl, and asserts the Cut transaction fires and the
saved file contains exactly the text with the word removed.

## Validation

```text
odin test tests/unit/mouse -vet -collection:hammer=src
    -> 16/16 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- mouse-test --no-config
    -> all 21 real X11 mouse checks passed, including the modifier Cut
odin run make.odin -file -- test
    -> all 436 core unit tests passed, allocator tracking clean
odin run make.odin -file -- typing-test --no-config
    -> all X11 typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed. The
modifier chord was exercised via XTest-synthesized Ctrl on Linux/X11 only; a
physical keyboard/trackpad combination and window-manager key interception were
not tested. The `2-1` chord path is unchanged and still physical-button only.

## Next task

Return to M08.detour-1: scroll the buffer when a right-arrow key press moves the
caret into a truncated area.
