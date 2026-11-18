# M07.02 — Buffer/view separation in the UI

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows and Wine remain unvalidated because the pre-existing Windows build
uses the unsupported `-ignore-vs-search` flag recorded in M07.01.

## Shared buffer, independent views

`Editor_Buffer` now owns the document, file path/capture/metadata, saved
revision, stable buffer ID, and generation. `src/core/view/view.odin` owns a
bounded set of views (up to the workspace's 8×16 windows). Each view has:

- Its stable window ID and referenced buffer ID.
- Independent selection, affinity, preferred visual column, and first-line
  viewport origin.
- Its own delayed-paste and delayed-cut request state.

M07.02 initially used three views of one buffer. M07.06 adds a bounded buffer
registry and changes the product default: the startup file belongs to the first
window, while the other initial windows are separate untitled buffers. Typing,
undo history, dirty state, and saves no longer propagate between those windows.
The view core still supports shared-buffer views for a future explicit
Zerox-style feature.

`src/view_ui.odin` performs stable-ID lookup, active-window transitions, and
post-edit synchronization. Switching windows ends the typing group and any
IME preedit so composition cannot jump between views.

## Editing and asynchronous results

After a successful transaction, `view.transform_after_edit` applies its
operations to selection anchors in other views of the same buffer. The
initiating view uses the transaction's exact resulting selection. Undo/redo
restores the active view's history selection and clamps other same-buffer
selections to valid byte offsets; it does not fabricate cross-branch anchor
mappings or modify views of other buffers.

Clipboard reads/writes are matched against every view's request ID. Results
are applied to the originating view and buffer ID/generation, even if another
window became active meanwhile. Existing anchor transformation and revision
validation remain in the editing package. Closing a view cancels its pending
operations; shutdown cancels all of them.

## Rendering and closing

`src/text_render_native.odin` collects glyphs for every view, renders each
view's selection, and draws a caret/IME preedit only for the active view.
Glyph draws carry their body rectangle so each is scissored to the correct
window. Hit-testing uses the active view's first line. The existing global
glyph budget remains shared and bounded.

Ctrl+W now closes only the active view when other views remain, including
when the shared buffer is dirty. The last dirty view still requires the same
close decision as before. A completed per-view close resets the lifecycle
close guard; this fixes the follow-up quit being rejected because the guard
remained in `Ready`.

## Tests and validation

`tests/unit/view/view_test.odin` covers independent view state,
operation-based selection transformation, history-jump clamping, view
removal/buffer view counts, and isolation between different buffer IDs. The
current `tests/integration/views/x11_harness.py` uses real pointer/key events
to prove independent selections, independent typing/saves, and safe closure of
one view without exiting the editor.

Commands run:

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin test tests/unit/view -vet -collection:hammer=src
    -> 4/4 passed, allocator tracking clean
odin run make.odin -file -- view-test --no-config
    -> all four independent-view X11 checks passed, clean shutdown
odin run make.odin -file -- layout-test --no-config
    -> all six M07.01 drag checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- test
    -> all 337 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 38 native text tests and four visual golden hashes passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run, real-desktop visual review, or scrolling test was
performed. Independent viewport origins are represented and honored by
render/hit-testing, but scrolling behavior belongs to M07.10. Tag editing and
product commands for creating additional buffers/views remain later tasks.

## Next task

M07.03 should make global, column, and window tags editable, derive their
command text from current buffer/view state, and route resulting edits
through the transaction engine without conflating tag and body selections.
