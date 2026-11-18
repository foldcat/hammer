# M07.detour-2–4 — Resize cursors, opener indentation, and clipboard-loss reporting

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Resize-control cursors

`src/mouse_ui.odin` maps the current layout hit to Sokol's standard cursors on
pointer movement. Column controls use the horizontal resize cursor, window
controls use the vertical resize cursor, and every other area restores the
default cursor. Existing layout dragging and scrollbar/text gestures are
unchanged.

`tests/integration/layout/x11_harness.py` now inspects the real server cursor
through XFixes before exercising the existing drag scenarios. It checks that
the column and window controls select distinct non-default images and that
moving back into a body restores the original image. The shared X11 helper
bounds and frees each cursor-image query.

## Enter indentation after an opening bracket

`src/core/editing/text_input.odin` retains newline inheritance and the existing
adjacent-pair expansion, and adds one indentation unit when the previous
non-whitespace byte before a collapsed caret is `(`, `[`, or `{`. Trailing
spaces and tabs are skipped when finding that opener. The operation remains one
typing transaction with bounded line reads and explicit indentation-setting
validation.

The product enables this behavior independently of `autopair`. With autopair
disabled, Enter after an opener indents but does not create an extra closing
line. With autopair enabled, Enter directly between matching brackets retains
the three-line expansion. The backend-free literal `perform` API keeps its
original behavior; product policy is explicit through `Input_Options`.

Unit cases cover end-of-document openers, trailing whitespace, inherited mixed
indentation, a non-adjacent closer, non-openers, and configurable spaces. The
X11 autopair harness verifies exact bytes after an opener without an adjacent
closer in both enabled and disabled product builds.

## Normal X11 clipboard ownership replacement

`src/platform/x11clipboard/owner.odin` still releases the old payload, cancels
its active INCR transfers, and queues a `.Lost` result when another client takes
a selection. That normal event no longer carries a `.Conflict` error, so the
generic editor reporter does not emit a warning or open an error window.
Acquisition, transfer, timeout, queue-overflow, and read failures retain their
error reporting.

The native X11 test checks that ownership loss remains observable without an
error and that reading with no owner still returns `.NotFound`. The product
typing harness takes ownership with an independent X11 client and checks that
the former warning text never appears.

## Validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin run make.odin -file -- layout-test --no-config
    -> real X11 cursor check and all six existing layout drag checks passed
odin test tests/unit/editing -vet -collection:hammer=src -define:ODIN_TEST_THREADS=1
    -> 47/47 tests passed, allocator tracking clean
odin run make.odin -file -- autopair-test
    -> enabled/disabled exact-byte product checks passed, including opener indentation
odin run make.odin -file -- clipboard-test
    -> 4/4 native tests and all separate-process interoperability checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save checks passed; ownership-loss warning absent
odin run make.odin -file -- test
    -> all 371 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
```

Validation used isolated Xvfb displays and temporary test state. No native
Windows/Wine run, Wayland compositor, or real-desktop visual review was
performed.

## Next task

M08.01 should implement command dispatch and context for the address/internal
command milestone.
