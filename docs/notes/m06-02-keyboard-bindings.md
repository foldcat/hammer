# M06.02 — Keyboard binding resolver

**Status:** done as a backend-free default binding resolver. Linux unit validation
and a Windows-target type check passed. The product window does not yet dispatch
through the resolver, and text insertion remains the next task.

## Resolver and actions

`src/core/keybind/keybind.odin` provides:

```text
resolve(input.Key_Down, has_selection) -> (keybind.Action, bool)
```

`keybind.Action` contains the M06.01 `editing.Move` and `editing.Select_All`
values directly, so resolved movement can be passed to `editing.perform` without
translation. It also defines semantic actions for copy, cut, paste, undo, redo,
save, save-as, find, finder, safe close/quit, indent/outdent, execute, and look.
Resolving those actions does not claim their owning subsystems are implemented.

The built-in bindings implement SPECS.md §10.3–10.4:

- arrows and Home/End, with Shift selection extension;
- Ctrl+Left/Right word motion and Ctrl+Home/End document motion, also with Shift;
- Ctrl+C/X/V, Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y, Ctrl+A, Ctrl+S, Ctrl+Shift+S,
  Ctrl+F, Ctrl+P, Ctrl+W, and Ctrl+Q;
- Ctrl+Enter execute and Alt+Enter look;
- Tab indent only with a nonempty selection, and Shift+Tab outdent.

Bindings require exact modifier sets. Ctrl+Alt is rejected before any lookup so
AltGr-produced text cannot trigger commands. Movement and movement selections
may auto-repeat; all one-shot commands, including select-all and indentation,
reject repeats. Unbound keys return `ok=false` without allocating or producing a
placeholder action.

Configurable keybinding files remain unsupported: the existing config resolver
explicitly rejects the reserved `keybindings` field rather than ignoring it.

## Tests

`tests/unit/keybind/keybind_test.odin` adds seven allocator-tracked tests for:

- every plain/Shift movement and selection binding;
- Ctrl word/document movement in both selection modes;
- every modern command default;
- repeatable movement versus non-repeating commands;
- Ctrl+Alt/AltGr rejection across navigation and command keys;
- selection-dependent Tab and unconditional Shift+Tab;
- unbound keys and exact modifier matching.

`make.odin` includes `tests/unit/keybind` in the core test target. The normalized
`input.Key_Down.repeat` comment now records the distinct one-shot and movement
policies.

## Validation

```text
odin test tests/unit/keybind -vet -collection:hammer=src
    -> 7/7 passed, allocator tracking clean
odin check src/core/keybind -no-entry-point -vet
    -> passed
odin check src/core/keybind -no-entry-point -vet -target:windows_amd64
    -> Windows-target type check passed; no Windows runtime test
odin run make.odin -file -- test
    -> all 271 core unit tests passed
odin run make.odin -file -- text-test
    -> all 26 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- build
    -> Linux debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> ten-frame lifecycle smoke passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- The resolver has no product-window consumer yet; real keyboard interception
  was not tested in this task.
- Resolved clipboard/save/find/execute actions are semantic values only, not
  implementations of those later-milestone features.
- M06.03 should separate text-input events from key commands, handle typing and
  editing keys through transactions, and ensure committed text does not also
  trigger a resolved shortcut.
