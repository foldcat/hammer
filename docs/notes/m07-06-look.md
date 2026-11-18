# M07.06 — Look expansion, file opening, and independent buffers

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Independent default buffers

At the user's direction, ordinary windows no longer share a document. M07.06
initially gave the startup file one window and two other windows independent
untitled buffers. M07.07 subsequently changed startup to one requested file or
untitled buffer on the left and an independent working-directory explorer on
the right. Typing, undo history, selections, dirty state, and saves are
independent. The core view code still supports multiple views of one buffer for
a future explicit Zerox-style operation.

`Editor` now owns a fixed-capacity registry of 128 stable buffer slots and a
monotonically increasing buffer-ID counter. Each slot owns its document, path,
load capture, metadata, and saved revision. The active-buffer pointer is a
borrowed pointer into this stable array, not an owner. Rendering, mouse target
resolution, tag generation, history jumps, and clipboard completion resolve the
buffer associated with their actual view rather than assuming the active one.
Selection transformation and history clamping skip views with different buffer
IDs. Closing the last view of a buffer destroys that buffer; shutdown destroys
all remaining buffers. Quit snapshots every buffer, so an inactive dirty buffer
still blocks lossy shutdown.

## Look expansion and opening

`src/core/mouse/look.odin` parses a trailing positive decimal line suffix:
`file.txt` has no line, while `file.txt:12` selects line 12. Invalid, zero,
empty, and overflowing suffixes are not treated as line addresses. Full Acme
address expressions remain M08 work. Look token expansion now also includes
backslashes for Windows paths; selected paths may contain spaces.

`src/look_ui.odin` implements the product path:

- Relative paths resolve against the source body/window-tag buffer's directory,
  or the process working directory for global/column tags. Absolute paths are
  supported. Normalization is lexical and does not require the target to exist.
- An already-open normalized path activates its existing view instead of
  duplicating the buffer. This is path-based reuse, not symlink/hard-link
  canonicalization.
- A new file is loaded and decoded through the existing regular-file,
  editable-UTF-8 path before layout is mutated. Only then are a new independent
  buffer, window, view, and generated tag created. Partial failures roll back
  all view/layout/buffer ownership.
- A valid one-based line suffix places the caret and viewport at that line. An
  out-of-range line reports an error without discarding the successfully opened
  file.
- A missing filename falls back to the existing wrapped literal search. Load,
  decode, path, capacity, and layout failures are reported without replacing or
  editing the source buffer.

Button 3, Alt+primary, Alt+Enter, and the built-in `Look` command all use this
same file-or-search path. Loading is synchronous in this slice; no asynchronous
result-application or large-file responsiveness claim is made. Directory and
error windows remain M07.07, and full addresses remain M08.

## Regression coverage

Mouse unit coverage now includes path suffix parsing, overflow/invalid forms,
and Windows-path token expansion. View unit coverage proves edit/history
transformations do not cross buffer IDs. The updated view X11 harness proves
independent selections, independent typing/saves, and safe view closure.

The new `look-test` X11 harness uses an isolated sandbox with relative,
absolute, missing, and Unicode paths. Its six scenarios cover `file:line`,
correct per-file saves, existing-view activation, independent source edits,
missing-file literal fallback, and quitting with an inactive dirty buffer.
`make.odin` exposes this as `look-test`.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- look-test --no-config
    -> all six Look/file-opening X11 checks passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-buffer/view checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all 20 mouse/modifier/chord checks passed
odin run make.odin -file -- layout-test --no-config
    -> all six layout checks passed
odin run make.odin -file -- tag-test --no-config
    -> all six tag checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- test
    -> all 357 core unit tests passed, allocator tracking clean
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

Intermediate product runs corrected test coordinates, byte offsets, buffer ID
initialization, and lexical missing-path normalization; the final suites above
all passed. No native Windows/Wine run, real-desktop visual review, asynchronous
large-file load, full address language, or directory-window behavior was
validated.

## Next task

M07.07 should add directory and error windows on top of the independent buffer
registry, with bounded directory reads, explicit error ownership, and the same
close/save safety rules.
