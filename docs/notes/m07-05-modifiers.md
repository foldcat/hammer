# M07.05 — Modifier-assisted gestures

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Mouse behavior

`src/core/mouse/mouse.odin` maps exact modifier sets at primary-button gesture
start:

- Plain and Shift+primary retain primary selection behavior.
- Ctrl+primary uses the existing Execute mode.
- Alt+primary uses the existing Look mode.
- Other combinations, including Ctrl+Alt (AltGr), Ctrl+Shift, Alt+Shift, and
  Super, do not start a primary gesture.

Modified gestures track their own action offsets through press, drag, and
release without emitting `Select_Start` or `Select_Update`. Execute/Look range
selection, token expansion, bounded text reads, conflicting-button
cancellation, lost-capture handling, and revision validation are shared with
buttons 2 and 3. Shift+button 3 remains the backward-Look gesture; Alt+Shift+
primary is intentionally not a second reverse binding.

`src/mouse_ui.odin` admits the two exact modified text gestures while keeping
Ctrl/Alt primary input from starting layout-control drags. Existing non-pointer
input, focus loss, and lost-button cancellation paths remain in force.

## Keyboard behavior

The existing Ctrl+Enter and Alt+Enter bindings are now connected in
`src/editor.odin`. They resolve the active body or tag target and pass its
selection's active offset to the same `editor_execute_mouse` and
`editor_look_mouse` handlers used by pointer gestures. A noncollapsed active
selection is executed/looked up as a whole; a collapsed caret expands the token
under it. No parallel command implementation or new allocation lifetime was
introduced.

Ctrl+Alt+Enter remains unbound. The existing keybind policy still rejects
commands for Ctrl+Alt while allowing printable AltGr text and IME commits, and
control-scalar commits cannot insert a newline while invoking these actions.

## Regression coverage

Two mouse state-machine tests bring `tests/unit/mouse` to 11 tests. They cover
Ctrl/Alt primary drags, the absence of selection actions, rejected modifier
combinations, and lost-capture cancellation. Existing keybind tests already
cover the exact Enter bindings, nonrepeat behavior, AltGr command rejection,
and printable AltGr input.

`tests/integration/mouse/x11_harness.py` now has 20 scenarios. New real-X11
checks cover Ctrl+primary Execute without primary selection, Alt+primary Look,
Ctrl/Alt+Enter through the shared handlers, Ctrl+Alt+Enter suppression, and
cancellation by non-pointer input. The strengthened 2-1 Look assertion now
waits for its own occurrence and drags across the complete `alpha` token rather
than accepting an earlier log line.

## Validation

```text
odin test tests/unit/mouse -vet -collection:hammer=src
    -> 11/11 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- mouse-test --no-config
    -> all 20 real X11 mouse checks passed
odin run make.odin -file -- test
    -> all 355 core unit tests passed, allocator tracking clean
odin run make.odin -file -- layout-test --no-config
    -> all six layout drag checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

Intermediate harness runs exposed empty/partial-token fixture coordinates; the
final corrected suite passed. No native Windows/Wine run, real-desktop visual
review, or window-manager Alt-drag interception test was performed.

## Next task

M07.06 should implement compatible Look token expansion and file opening while
preserving bounded input, stable view/buffer identity, dirty-file safety, and
revision validation.
