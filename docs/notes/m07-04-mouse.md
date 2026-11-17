# M07.04 — Original mouse actions and chords

**Status:** done on Linux/X11. Windows source type-checking passes. Native
Windows/Wine remains unvalidated because of the pre-existing build blocker
recorded in M07.01.

## Gesture state machine

`src/core/mouse/mouse.odin` is a backend-free pressed-button state machine. It
tracks the initial stable text target, byte-range origin, pointer drag
threshold, gesture-start modifiers, chord state, double-click timing, and
cancellation. Button 1 selects, button 2 executes on final release, and button
3 looks on final release. Execute/look chords with a conflicting button cancel
rather than firing on release. Lost held-button state, focus loss, invalid
geometry, unavailable targets, and non-pointer input cancel the gesture.

A collapsed execute/look action uses the containing primary selection or a
bounded Unicode-aware token expansion. Button-1 double-click expands words,
matching bracket/quote interiors, and lines. Action text is limited to 64 KiB;
token scans are bounded in both directions and reject truncated over-budget
tokens instead of executing them.

## Original chords and command behavior

The supported original chords are wired through `src/mouse_ui.odin`:

- 1-2 cuts and 1-3 pastes using the native clipboard. Paste replaces a
  selection or inserts at a collapsed caret; a collapsed caret is not rejected.
- 1-2 followed by 1-3 is Snarf: a pending cut is logically canceled after its
  clipboard write starts, while a completed cut is undone and the original
  selection restored. The body returns to its prior revision.
- 1-3 followed by 1-2 cancels a pending paste or undoes only the completed
  chord paste, leaving the text unchanged.

A successful mouse-chord paste leaves the inserted range selected, including
when it was inserted at a collapsed caret. Ordinary Ctrl+V and button-2
`Paste` retain the normal collapsed post-paste caret. Chord completion computes
the range from the exact post-paste caret and clipboard payload length.
- 2-1 passes the last primary selection as a distinct argument. It is used by
  the built-in `Look` command.
- Shift at button-3 gesture start searches backward.

Clipboard completions retain stable buffer/view/tag identities and request IDs.
Chord completion also records the exact transaction ID. Reversal refuses to
undo if the current transaction no longer matches. A document revision or
generation change from any other operation invalidates the in-progress gesture;
only the chord's own completion/reversal advances its captured revision.

Button 2 currently dispatches the existing built-ins `Del`, `Exit`, `Put`,
`Undo`, `Redo`, `Cut`, `Snarf`, `Paste`, and `Look`. `Del` and `Exit` use the
existing data-safe close state machine. Other text is explicitly logged as not
executed: the full internal registry belongs to M08 and asynchronous external
commands to M09. There is no shell fallback and no X11 middle-click-paste
behavior.

Button 3 performs literal wrapped forward/backward search and selects the
match. Search streams rope spans with a 64 KiB needle limit and a 64 MiB
document budget; it does not flatten the body and reports over-budget input
explicitly. Full Look expansion, addresses, and file opening belong to M07.06.
Modifier-assisted primary-button gestures belong to M07.05. HTML-tag-specific
double-click matching remains a compatibility-gap candidate for M07.08.

## Tests and validation

Nine unit tests in `tests/unit/mouse` cover gesture transitions, double-click
and reversal chords, 2-1 arguments, conflicting-button cancellation, lost
capture, Unicode/token bounds, bracket/line expansion, and wrapped search over
small rope chunks.

`tests/integration/mouse/x11_harness.py` uses real X11 events and an external
clipboard owner in a unique sandbox. Its fourteen scenarios cover button-3
literal search, 2-1 `Look`, double-click plus 1-2-3 Snarf, collapsed-caret
chord insertion and highlighting, ordinary Ctrl+V without highlighting,
quick-release paste from Hammer's own clipboard, 1-3-2 paste reversal,
button-2 `Put`, selected unknown text not creating a marker file, exact tag
hit-testing, tag `Del` closing one view safely, empty-clipboard recovery, and
line/document-end cuts. The final scenario performs ten cut/undo cycles after
a failed paste and checks exact saved bytes and render health after every
cycle. `odin run make.odin -file -- mouse-test --no-config` builds and runs
this harness.

A follow-up regression reproduced a two-glyph window-tag caret error: mouse
hit-testing used the full tag rectangle while rendering used the inner content
rectangle. Global, column, and window tag hit-testing now use the same padding
and control offsets as rendering. The regression clicks before `Del`, inserts
`x`, and verifies the exact tag bytes through the native clipboard.

The empty-owner/UTF-8-refusal clipboard warning was also exercised directly.
It leaves the document unchanged and later chords recover. Quick-release paste
from Hammer's own Snarf-owned clipboard passed ten consecutive stress runs;
pointer motion during the chord was included.

A user log subsequently isolated the drag-to-end symptom: one Cut transaction
was followed by `rope: byte offset 11 outside [0, 4]` in the renderer, not by a
second deletion. `view.transform_after_edit` now clamps every other view's
selection to the new document length, including stale selections that predate
the edit. The text renderer also bounds its local selection before computing
the caret line, so a stale view cannot abort drawing of the remaining text. A
view unit test covers the exact 11-to-4-byte case. Stress runs checked exact
bytes after hundreds of document-end cut/undo transactions, including cycles
preceded by a failed paste.

Commands run successfully:

```text
odin test tests/unit/mouse -vet -collection:hammer=src
    -> 9/9 passed, allocator tracking clean
odin test tests/unit/view -vet -collection:hammer=src
    -> 6/6 passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- mouse-test --no-config
    -> all fourteen X11 mouse checks passed
odin run make.odin -file -- test
    -> all 351 core unit tests passed, allocator tracking clean
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- layout-test --no-config
    -> all six drag checks passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-view checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin run make.odin -file -- text-test
    -> all 38 native text tests and four visual golden hashes passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

The product regressions and mouse harness were rerun after the final
view-selection and renderer changes. No native Windows/Wine run or real-desktop
visual review was performed. Completed chord reversal was exercised, but a
forced still-pending clipboard reversal race was not deterministically
injected. Windows pointer behavior is source-checked only.

## Next task

M07.05 should map Ctrl+primary to Execute and Alt+primary to Look, connect
Ctrl+Enter and Alt+Enter through the same action layer, and prove that
modifier-assisted gestures do not accidentally start primary selection or text
dragging. Include cancellation, AltGr text-input protection, and X11 product
coverage.
