# M06.15 — Basic CLI file open and Ctrl+S save

**Status:** done on Linux/X11. The product opens one existing file supplied as
`hammer filename` and saves that file with Ctrl+S. Windows product behavior was
not exercised.

## Startup loading

`src/main.odin` accepts zero or one positional argument. More than one filename
is rejected with `usage: hammer [filename]`. With no filename, the existing empty
untitled document remains available.

`src/editor.odin` loads a named file through the existing `core/fileload` and
`core/filecodec` packages. Only regular files containing valid editable UTF-8
enter the document; invalid UTF-8 and unsupported Unicode encodings fail startup
rather than being silently replaced. A UTF-8 BOM is metadata rather than document
text. Original BOM and newline metadata, the load-time disk checkpoint, and an
owned path copy are retained beside the revision-0 `txn.Doc`.

Loading and copying into the revision-0 document are synchronous in this basic
slice. Raw load chunks and the temporary flattened copy use frame scratch; the
document owns its own copied content in the permanent arena. A load error that
must outlive the frame is copied into the permanent arena before being transferred
to the lifecycle.

## Ctrl+S and dirty state

The existing Ctrl+S key binding now calls `core/filesave.save_tree` with the
current immutable root, current revision, original encoding metadata, and
`.Unchanged` disk policy. Safe save therefore retains temporary-file publication,
sync-before-replace, permission handling, symlink following, and external-change
checks. Clean buffers are not rewritten.

A successful result updates the saved revision and disk checkpoint only if its
revision still matches the current document. Every failure leaves the saved
revision unchanged, so the existing close guard continues to block lossy close.
A post-publication error is logged as requiring deliberate review rather than an
automatic retry. Save errors and temporary paths use frame scratch and do not
accumulate in the permanent arena.

Ctrl+S on an untitled document reports that no destination is available. It does
not invent a filename or write an unspecified path.

## Save As explicitly deferred

Ctrl+Shift+S remains resolver-only and performs no file operation. **Save As is
deferred until the tag bar and command implementation can request a destination
path explicitly.** This task does not add a file dialog, implicit destination, or
no-clobber Save As product path. The underlying `filesave.Must_Not_Exist` policy
remains available for that later integration.

## Product regression coverage

`tests/integration/typing/x11_harness.py` now launches the real binary with a
relative filename containing spaces. It appends text with real X11 key events,
saves with Ctrl+S, and checks exact bytes including a UTF-8 BOM and CRLF newlines.
It then reopens the saved file, appends and saves again, and verifies the complete
round trip.

For the failure path, the harness edits the buffer, modifies the file externally,
and presses Ctrl+S. It verifies that the external bytes remain on disk and Escape
cannot close the dirty editor. Undoing the local edit returns to the saved
revision and permits an orderly close.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin run make.odin -file -- build
    -> Linux debug product build passed
odin run make.odin -file -- typing-test
    -> all real X11 typing/clipboard/zoom checks passed
    -> CLI relative-path open, exact BOM/CRLF save, reopen, conflict, and
       dirty-close checks passed
odin run make.odin -file -- test
    -> all 324 core unit tests passed with allocator tracking enabled
```

## Limits and next task

- Startup load and Ctrl+S are synchronous; large-file UI responsiveness and
  asynchronous product integration are not claimed.
- Only valid UTF-8 files are editable in this slice. New-file creation, Save As,
  external-change resolution UI, and explicit overwrite remain unavailable.
- Windows, Wayland, and real non-X11 product input were not validated.
- Next is M06-Detour-3: implement Windows font discovery/rendering and validate
  the Windows product path without weakening the existing Linux renderer.
