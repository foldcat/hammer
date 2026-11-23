# M10.detour-1 — Two-column startup without an empty buffer

**Status:** done on Linux/X11. Windows runtime was not exercised.

## Behavior

No-argument startup now creates two columns and one buffer/view: the
working-directory explorer remains open in the right column and is active,
while the left column starts empty. No untitled file buffer is allocated.
Starting with a file or directory argument retains the previous two-window
layout: the requested buffer on the left and the working-directory explorer on
the right.

`src/editor.odin` skips initial buffer allocation when no path was supplied,
selects the first real view as active, and logs the startup column/window/buffer
counts. Explicit `New` remains available for creating an untitled buffer.

## Tests

The view integration scenario asserts no-argument startup has two columns, one
window, one buffer, and the explorer active. Existing integration scenarios
that require an untitled buffer now execute the real `New` command through the
shared `open_untitled` X11 helper rather than relying on implicit startup
state.

## Validation

```text
odin run make.odin -file -- view-test       -> passed, including startup assertion
odin run make.odin -file -- layout-test     -> all 7 X11 checks passed
odin run make.odin -file -- tag-test        -> all 13 X11 checks passed
odin run make.odin -file -- typing-test     -> all typing/clipboard/save checks passed
odin run make.odin -file -- autopair-test   -> enabled/disabled checks passed
odin run make.odin -file -- ligature-test   -> enabled/disabled checks passed
odin run make.odin -file -- emoji-test      -> all X11 emoji checks passed
odin run make.odin -file -- unicode-test    -> all 12 Unicode lines and clipboard checks passed
odin run make.odin -file -- directory-test  -> all directory/error checks passed
git diff --check                           -> clean
```

An initial version of the change accidentally produced zero windows without a
path argument; the view regression caught it, and always creating the right
explorer window fixed it before the successful runs above.

## Next task

Return to M10.07d: exercise complex terminal applications such as Neovim and
htop and verify their advertised terminal interactions.
