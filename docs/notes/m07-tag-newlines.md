# Hotfix — Single-line tag buffers

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Problem

Plain Enter in a global, column, or window tag inserted a newline. The tag
renderer is a single-line strip, so the newly created line was invisible and
made the tag appear to lose text.

## Fix

`src/editor.odin` rejects CR and LF in `editing.Insert_Text` and
`editing.Commit_Text` whenever the active document is any tag. This covers
ordinary Enter, keypad Enter, and Enter-driven editing policies without
changing body newline behavior.

`src/clipboard_views.odin` checks tag clipboard payloads before calling the
transaction engine. Any payload containing CR or LF is rejected as a whole and
the pending paste is canceled; no prefix is inserted and the tag selection is
left unchanged. Ordinary Ctrl+V and mouse-chord paste share this path. The
warning is `tag: newline input is not allowed`.

This is an input boundary rule, not a renderer workaround or silent newline
normalization. Existing generated tag prefixes are already single-line.

## Regression coverage

`tests/integration/tags/x11_harness.py` now has eight scenarios. The new checks
copy `a\nb` through the real native clipboard, verify that tag paste rejects it
without changing tag or body pixels, and verify that Enter and keypad Enter
leave the tag unchanged.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- tag-test --no-config
    -> all eight editable/generated/single-line-tag checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all 20 mouse/chord checks passed
odin run make.odin -file -- typing-test --no-config
    -> all body typing/newline/clipboard/save checks passed
odin run make.odin -file -- test
    -> all 357 core unit tests passed, allocator tracking clean
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed.
