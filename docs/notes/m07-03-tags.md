# M07.03 — Tag editing and generated command state

**Status:** done on Linux/X11. Windows source type-checking passes. Native
Windows/Wine remains blocked by the pre-existing unsupported
`-ignore-vs-search` build flag documented in M07.01.

## Editable tag documents

Global, column, and per-window tags are independent `txn.Doc` values with
their own selections and delayed clipboard requests. `src/core/tag/tag.odin`
owns initialization, destruction, and generated-prefix replacement.

Pointer focus distinguishes body, global tag, column tag, and window tag.
Keyboard editing, mouse selection, undo/redo, indentation, copy/cut/paste,
and IME commit operate on the active document. Tags are single-line: Enter,
keypad Enter, CR/LF text commits, and clipboard/chord pastes containing CR or
LF are rejected without a transaction (see `m07-tag-newlines.md`). Clipboard
completions retain stable tag/body buffer identities and return to the
originating view/tag. Closing a view or shutting down cancels its tag requests
and destroys its tag document. Tag text is UI command state, not file content,
and does not make the file buffer dirty.

`src/core/view/view.odin` now uses stable slots with holes. `txn.Doc` is
fixed-location, so views are never compacted by copying. A regression test
pins tag document addresses across view removal; this fixed a shutdown crash
found by the first real-window tag test.

## Generated commands

Window tags begin with a generated basename and command prefix:

- Clean buffer: `name Del | `
- Dirty buffer: `name Del Put | `

Body edits, undo/redo, and successful saves refresh every view's prefix.
Replacement is a tag-local transaction that transforms the tag selection and
leaves the user suffix in place. Refresh rediscovers the first ` | ` delimiter
on every call, so editing or deleting the generated prefix cannot leave a
stale boundary that corrupts the suffix. Generated text is bounded to 4096
bytes and identical refreshes do not create transactions.

Global and column tags currently start as `Newcol | ` and `New | `. These
commands are displayed/editable but not executed here; original mouse
execution/chords and the internal command registry belong to M07.04/M08.

## Rendering

The shared text renderer accepts an explicit document and rectangle for body
and tags. Every tag is rendered with independent selection state; only the
active body/tag gets a caret or IME preedit. Tag glyphs are scissored to their
content rectangle. Tags use their actual strip height for caret/selection
quads, preventing body-height carets from spilling into the body.

The older typing harness now hashes body pixels only. Backspace restores text
but creates a dirty revision, so retaining `Put` is correct; the tag suite
checks that behavior separately instead of treating it as a pixel mismatch.

## Tests and validation

Three tag unit tests cover suffix/selection preservation, adding/removing
`Put`, no-op refresh revisions, input validation, and repair after deleting
the generated prefix. A fifth view unit test pins fixed-location ownership.
`tests/integration/tags/x11_harness.py` covers real typing into all three tag
kinds, body/tag isolation, dirty `Put` generation, clean-state removal, and
single-line enforcement for Enter and CR/LF clipboard input.

Commands run:

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin test tests/unit/tag -vet -collection:hammer=src
    -> 3/3 passed, allocator tracking clean
odin test tests/unit/view -vet -collection:hammer=src
    -> 5/5 passed, allocator tracking clean
odin run make.odin -file -- tag-test --no-config
    -> all five editable/generated-tag X11 checks passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-view checks passed
odin run make.odin -file -- layout-test --no-config
    -> all six drag checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- test
    -> all 341 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 38 native text tests and four visual golden hashes passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed.
Command execution, tag-specific mouse chords, directory tags, and persistent
layout restoration are not claimed.

## Next task

M07.04 should recognize original button-2 execution and button-3 Look plus
supported chords, with explicit pressed-button/drag state and cancellation.
Execution should read the selected tag/body text without confusing selection,
layout dragging, or text dragging, and must not run commands from untrusted
content implicitly.
