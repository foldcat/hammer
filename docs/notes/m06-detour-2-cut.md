# M06-Detour-2 — Cut and Shift clipboard aliases

**Status:** done on Linux/X11 with real product-window and external-application
validation. Shared dispatch and backend-free cut completion are implemented for
both platform families. The Windows product cross-build is blocked by the existing
`-ignore-vs-search` invocation, which the installed pinned compiler rejects before
compiling source. Windows product shortcuts and Wayland remain unvalidated.

## Keybindings and cut completion

`src/core/keybind/keybind.odin` now resolves Ctrl+Shift+C to `Copy` and
Ctrl+Shift+V to `Paste`, with the same exact-modifier and no-auto-repeat policy as
the unshifted shortcuts. Ctrl+X resolves to the existing `Cut` action.

`src/core/editing/cut.odin` adds a fixed-location, allocation-free `Delayed_Cut`
state. Beginning a cut captures buffer ID 1, generation 1, a nonzero request ID,
the source revision, and both selection anchors. Successful completion transforms
those anchors through intervening edits on the current history path and deletes
the captured range through one `.Cut` transaction, collapsing the caret to the
range start. Empty selections, invalid targets, abandoned history, and transaction
failures do not delete text. Request/target mismatches remain pending for their
actual result; cancellation and duplicate/late results are harmless.

`src/editor.odin` connects `Cut` to the native clipboard and shares bounded
selection reading with copy. It starts no native request until target capture
succeeds. Most importantly, deletion waits for a successful clipboard-write poll:
Windows reports native write failure in that result even when `start` returns
success, so deleting immediately after `start` would be unsafe. A matching write
error cancels only the pending deletion and leaves the document unchanged. Native
write ownership and result/error cleanup retain their existing owners.

## Regression coverage

`tests/unit/editing/cut_test.odin` covers successful reverse-selection cut,
intervening-edit anchor transformation, target/request mismatches, cancellation,
duplicate results, abandoned history, and invalid input. The keybind suite covers
all default bindings and keeps Ctrl+Shift+X unbound.

`tests/integration/typing/x11_harness.py` uses its isolated Xvfb session and a
separate clipboard process to verify:

- Ctrl+X publishes the selected bytes and removes them from the product window;
- one Ctrl+Z restores the complete cut text;
- Ctrl+Shift+V pastes the cut bytes;
- Ctrl+Shift+C publishes the selection without changing text or selection;
- undo restores the initial document after the alias/cut sequence.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin test tests/unit/editing -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 32 editing tests passed, allocator tracking clean
odin test tests/unit/keybind -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 13 keybind tests passed, allocator tracking clean
odin run make.odin -file -- typing-test
    -> Linux debug product build and all typing/mouse/clipboard checks passed
    -> cut, cut undo, Ctrl+Shift+C, and Ctrl+Shift+V passed end to end
odin run make.odin -file -- test
    -> all 307 core unit tests passed, allocator tracking clean
odin run make.odin -file -- clipboard-test
    -> 4/4 native X11 tests and all separate-process/xclip/manager checks passed
odin run make.odin -file -- windows
    -> blocked before source compilation: Unknown flag: 'ignore-vs-search'
```

The pinned compiler has no `odin fmt` command and no `odinfmt` executable is
installed. Formatting was reviewed manually.

## Limits and next task

- No Windows product build or product-key event run was available in this session.
  The user noted that recent Windows path/linker tweaks may have affected Linux
  cross-builds; those unrelated build settings were not changed by this task.
- Native clipboard-write failure is covered by the pending-cut state machine, but
  was not injected through a real Windows or X11 product clipboard failure.
- Wayland clipboard and product integration remain unsupported/unvalidated.
- Next is M06.12: Enter must inherit the current line's indentation through one
  transaction, with editing unit tests and real X11 product coverage.
