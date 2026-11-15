# M06.08 — Clipboard interoperability tests

**Status:** done for Linux/X11 under isolated Xvfb and Windows under isolated
Wine/Xvfb. Real Windows, a real desktop clipboard manager, and Wayland were not
validated.

## Separate-process coverage

`tests/integration/clipboard/driver` is a small CLI around the product X11
clipboard service. `tests/integration/clipboard/interop_harness.py` runs it
against the independent X11 peer in `spike/clipboard` and against xclip 0.13.
The checks cover both directions for `CLIPBOARD`, both directions for `PRIMARY`,
and xclip reads from Hammer owners. The 72-byte fixture includes Latin accents,
Greek, Cyrillic, CJK, combining marks, emoji, and RTL text. A repeated 262,152-byte
Unicode fixture exceeds the 64 KiB threshold and exercises INCR in both
directions, including through xclip.

The spike gained a test-only `manage` mode implementing the UTF8_STRING subset
of `SAVE_TARGETS`. The harness starts it as a separate clipboard-manager process,
exits the Hammer owner, and verifies that a new external reader receives the
same Unicode payload. This validates Hammer's manager-handoff protocol; it does
not claim compatibility with every desktop clipboard manager.

`tests/integration/clipboard_windows` now has product-service and independent
raw-Win32 peer modes. Its Python harness checks Hammer writer to external reader
and external writer to Hammer reader for the same Unicode and 262,152-byte
fixtures. Each writer remains alive until the reader completes. Wine did not
provide `CF_UNICODETEXT` to a new process after the first writer exited, so these
tests deliberately make no Windows post-exit persistence claim.

## Isolation and bounds

Both harnesses create unique temporary sandboxes, use bounded subprocess
timeouts, avoid shell commands, and terminate every owned long-lived helper.
Linux runs on a fresh Xvfb display and never accesses the user's desktop
clipboard. Windows uses a fresh `WINEPREFIX` on a fresh Xvfb display and stops
only that prefix's wineserver during cleanup. Payloads are transferred through
files rather than unbounded protocol streams on stdout. Successful runs remove
their sandboxes; failures preserve them for diagnosis.

The existing `clipboard-test` and `clipboard-windows-test` build targets now run
these checks after the original native tests, so no separate acceptance command
is required.

## Validation

Using pinned Odin `dev-2026-11`, xclip 0.13, and Wine 11.0:

```text
odin run make.odin -file -- clipboard-test
    -> original 4/4 X11 native tests passed, allocator tracking clean
    -> all separate-process Unicode, PRIMARY, 256 KiB INCR, xclip, and
       SAVE_TARGETS persistence checks passed
odin run make.odin -file -- clipboard-windows-test
    -> original Windows/Wine native checks passed
    -> all four separate-process Win32 Unicode and large-transfer checks passed
odin check make.odin -file -vet
odin check tests/integration/clipboard/driver -vet -collection:hammer=src
odin check tests/integration/clipboard_windows -target:windows_amd64 -no-thread-local -vet -collection:hammer=src
    -> all checks passed
odin run make.odin -file -- test
    -> every core unit package passed
odin run make.odin -file -- build
    -> Linux debug product build passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- No real Windows host, Wayland compositor, real desktop clipboard manager, or
  real desktop session was exercised. X11 external-application coverage uses the
  purpose-built peer and xclip; Windows uses the purpose-built raw-Win32 peer
  under Wine.
- The custom X11 manager implements only the UTF8_STRING handoff needed by this
  test, not every target a full desktop manager may request.
- Windows clipboard persistence after owner exit remains unvalidated. The Wine
  interoperability checks require the owner to remain alive until reading ends.
- M06.09 should consume product text-input commits and render typed text through
  the ordinary transaction path, with undoable typed characters in the product
  window.
