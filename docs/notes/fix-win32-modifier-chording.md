# Fix — Windows Ctrl/Alt+click modifier chording

**Status:** done on Windows (native build + synthetic-input reproduction of both
failure modes). Two independent defects were found: one in the pinned Sokol C
backend and one in the editor's input dispatch. Real laptop-trackpad hardware
was not available; the user's own trackpad log was used to confirm the second
defect.

## Problem

`Ctrl+click` (Execute / middle-click) and `Alt+click` (Look / right-click), and
the `Ctrl`/`Alt`-while-holding-button-1 chords (Cut/Paste), did not register on
Windows. A `Ctrl`/`Alt`+click was treated as a plain left-click selection.

## Defect 1 — modifier mask dropped (Sokol backend)

Sokol's `_sapp_win32_mods()` built the modifier mask with `GetKeyState`:

```c
if (GetKeyState(VK_CONTROL) & (1<<15)) { mods |= SAPP_MODIFIER_CTRL; }
```

`GetKeyState` reports the key state **as of the last keyboard message read from
the thread's message queue**, not the current hardware state. For a mouse event
this is the wrong function: a `Ctrl`/`Alt`+click delivered before the queue has
processed the key-down — routine with fast synthetic clicks from a laptop
trackpad, where the touchpad driver and the keyboard arrive on different input
paths — loses its modifier. Microsoft's own `GetKeyState` documentation states
the interrupt-level state requires `GetAsyncKeyState`, which is exactly what the
button bits below already used.

### Fix 1

`make.odin` gains `patch_sokol_win32_modifiers`, applied by `setup_windows`
(both the native Windows build and the Linux cross-build). It rewrites the
`GetKeyState(` prefix to `GetAsyncKeyState(` inside `_sapp_win32_mods`, so the
five modifier probes (Shift/Ctrl/Alt/LWin/RWin) read the interrupt-level state.
Done in-process with `strings.replace_all` rather than the external `patch` tool
(the BusyBox `patch` on Windows lacks `-d`/`--no-backup-if-mismatch`), it is
exact (`GetKeyState(` appears only in this function) and idempotent, and
invalidates the `sokol_app` libs so they rebuild from the patched header.

## Defect 2 — key auto-repeat cancels the gesture (editor)

With the modifier mask fixed, the user's trackpad log still showed the gesture
failing — the pointer press arrived with `mods=CTRL`, but no Execute fired.
The log's tell was the stream of `key down LEFT_CONTROL (repeat)` events:
holding `Ctrl` while clicking makes Windows auto-repeat the key.

`editor_consume_input` routes every `Key_Down`/`Key_Up` through
`editor_modifier_chord`, then cancels the pointer gesture for anything that
returns `false`. `editor_modifier_chord` only handled the chord (Select mode)
and returned `false` for Execute/Look mode, so a repeated `Ctrl` press during a
`Ctrl`+click fell through to `editor_cancel_pointer_gesture()` and cancelled the
Execute gesture before the pointer-up could fire it. (The first synthetic
harness missed this because `keybd_event`/`SendInput` do not auto-repeat a held
key; only a physical keyboard does.)

### Fix 2

`src/mouse_ui.odin` — `editor_modifier_chord` now consumes a repeated Ctrl/Alt
press in **every** gesture mode before the mode check:

```odin
if kd, is_down := event.(input.Key_Down); is_down && kd.repeat {
    _, ok := modifier_chord_button(kd.key)
    return ok
}
```

A repeated Ctrl/Alt is the OS auto-repeat of an already-held key, not a fresh
key press, so it must never cancel the gesture (in Execute/Look mode the held
modifier is the one that started the gesture). A non-modifier repeat still
returns `false` and cancels as before, and non-repeat modifier keys in
Execute/Look mode still cancel, preserving the documented behaviour.

## Validation

```text
odin check make.odin -file -vet
    -> passed
odin run make.odin -file -- windows
    -> build ok; "Applied the pinned Sokol win32 modifier-state patch"; Sokol libs rebuilt
odin test tests/unit/mouse -vet -collection:hammer=src
    -> 16/16 passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

Two synthetic-input harnesses against the real `hammer.exe` confirmed the fixed
behaviour end-to-end:

- Baseline: `Ctrl+click` → `mods=CTRL` + Execute, `Alt+click` → `mods=ALT`,
  hold-button-1 + `Ctrl` → Cut chord.
- Held-`Ctrl`-with-auto-repeat: repeated `key down LEFT_CONTROL (repeat)` events
  during the held click no longer cancel, and `mouse: execute ...` fires on the
  pointer-up.

## Not validated

- Real laptop-trackpad hardware (synthetic mouse/keyboard events were used; the
  user's real-trackpad log reproduced defect 2, but the fixed binary has not yet
  been confirmed on the physical trackpad).
- The Linux cross-build path (`odin run make.odin -file -- windows` on Linux)
  was not re-run; `patch_sokol_win32_modifiers` is platform-independent Odin,
  but only the native Windows build was exercised.
- The full `odin run make.odin -file -- test` suite: one pre-existing failure
  in `command_test.test_filter_discovery_scopes_availability_and_atomic_reload`
  (Windows `\` vs `/` path-separator expectation), unrelated to this change and
  untouched here.
