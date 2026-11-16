# M06.11 — Copy and paste keybindings

**Status:** done on Linux/X11 with real product-window and external-application
validation. The shared dispatch and Windows native service are wired and the
Windows product cross-build and native clipboard suite pass under Wine. Ctrl+C /
Ctrl+V in the Windows product window and every Wayland compositor remain
unvalidated.

## Product dispatch and lifetime

`src/editor.odin` now consumes the existing `keybind.Copy` and `keybind.Paste`
actions instead of logging them as unconnected.

- Ctrl+C leaves an empty selection untouched. A nonempty directional selection is
  normalized to a byte range and read directly from the rope without flattening
  the document. Selections over the 64 MiB clipboard budget are rejected before
  allocation. The range buffer belongs to the frame arena and is released after
  `start`; the native service owns its retained clone.
- Ctrl+V captures buffer ID 1, generation 1, the current selection anchors, source
  revision, and a fresh nonzero request ID through `editing.delayed_paste_begin`
  before starting native I/O. Results apply only to that captured target through
  `delayed_paste_apply`, producing one `.Paste` transaction and a collapsed caret.
- The UI thread polls at most one native result per frame and before starting an
  operation. Result payloads and errors are destroyed exactly once. A native read
  error cancels its matching delayed paste, while late or unrelated results cannot
  paste into the current selection. Shutdown cancels native I/O and the delayed
  target before document and clipboard teardown.
- `src/clipboard_linux.odin`, `src/clipboard_windows.odin`, and
  `src/clipboard_other.odin` own product service initialization and destruction.
  Linux initialization failure leaves ordinary editing available and reports an
  explicit unavailable-service error if copy or paste is requested.

## Product interoperability coverage

`make.odin -- typing-test` now builds the independent X11 clipboard peer and runs
the extended `tests/integration/typing/x11_harness.py` in an isolated Xvfb
session. In addition to the existing typing, mouse, undo, and close checks, the
harness verifies:

- paste with no clipboard owner leaves the document unchanged and cancels the
  pending request so later operations work;
- Ctrl+C publishes the selected `product-copy` bytes to a separate-process
  external reader;
- Ctrl+V replaces the selection with a Unicode payload from a separate-process
  external owner, including accents, Greek, CJK, a combining mark, emoji, and LF;
  copying the result back to the external reader confirms every byte;
- one undo removes the paste and a second removes the source typing run, restoring
  the initial pixels.

The harness owns bounded readiness/read timeouts and cleans up the external owner
on readiness failure, ordinary completion, and test failure. Successful runs
remove their unique sandbox; no real desktop clipboard is accessed.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin run make.odin -file -- build
    -> Linux debug product build passed
odin run make.odin -file -- typing-test
    -> all typing/mouse checks passed
    -> no-owner recovery, external copy, external Unicode paste/round-trip,
       and paste undo passed
odin run make.odin -file -- test
    -> all 300 core unit tests passed, allocator tracking clean
odin run make.odin -file -- clipboard-test
    -> 4/4 native X11 tests and all separate-process/xclip/manager checks passed
odin run make.odin -file -- text-test
    -> all 28 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- windows
    -> Windows product cross-build passed
odin run make.odin -file -- clipboard-windows-test
    -> Windows/Wine native Unicode, empty, large, malformed-input, PRIMARY,
       and separate-process interoperability checks passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> Linux lifecycle smoke passed
xvfb-run -a env WINEDEBUG=-all HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine ./build/hammer.exe
    -> Windows/Wine lifecycle smoke passed; native font discovery remains unsupported
```

The pinned compiler has no `odin fmt` command and no `odinfmt` executable is
installed. Formatting was reviewed manually; `git diff --check` passed.

## Limits and next task

- No real Windows host or Windows product-key event test was available. Wine
  validates the native clipboard service and product lifecycle, not Windows
  product Ctrl+C/Ctrl+V end to end.
- Wayland clipboard and product integration remain unsupported/unvalidated.
- Cut, PRIMARY keyboard paste, and Acme mouse chords are separate tasks.
- Per the requested roadmap order, the next task is reopened M05.09 (native
  ligature coverage and configuration), followed by M05.10 before M06.12.
