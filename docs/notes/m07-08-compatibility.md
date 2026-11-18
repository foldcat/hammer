# M07.08 — Window-behavior compatibility scenarios

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Compatibility contract

`docs/acme-compatibility.md` now separates preserved behavior, intentional
modernization, and unsupported/deferred behavior. It records the current test
coverage and explicitly avoids claiming the full command registry, product
Zerox, scrolling, wrapping, IPC, or external commands before their milestones.

## Integrated product scenario

`tests/integration/compatibility/x11_harness.py`, exposed by `make.odin` as
`compatibility-test`, runs in a unique sandbox with the sandbox as the process
working directory. Real X11 mouse/key events exercise seven connected stages:

1. A requested file opens beside the working-directory explorer.
2. Primary selection and editing generate `Put`; button 2 on the tag saves the
   exact selected replacement.
3. Button 3 on an explorer entry opens an independent file buffer.
4. The new window drags from the explorer column into the source column.
5. Repeated directory-save errors reuse one `+Errors` window without stealing
   the originating window.
6. Quit remains blocked by an inactive dirty buffer after those operations.
7. Undo restores clean state, button-2 `Del` closes the saved source through the
   shared guard, and a final quit exits cleanly.

Intermediate failures were fixture/event-coordinate corrections. A temporary
hit diagnostic confirmed that explorer Look opens in the explorer's column and
that dropping above the source inserts at index 0. The diagnostic was removed;
no product behavior needed to change for this task.

## Validation

```text
odin run make.odin -file -- compatibility-test --no-config
    -> all seven integrated compatibility stages passed
odin run make.odin -file -- layout-test --no-config
    -> all six layout checks passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-buffer/view checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin run make.odin -file -- look-test --no-config
    -> all six Look/file-opening checks passed
odin run make.odin -file -- directory-test --no-config
    -> all six directory/error checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- test
    -> all 362 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed. The
scenario verifies state transitions, file bytes, layout events, and process
lifecycle; it is not a pixel-based Acme appearance comparison.

## Next task

M07.09 should implement configurable soft wrapping versus truncation with
horizontal scrolling, with coordinate/hit-testing tests across long and Unicode
lines and regression coverage for independent viewports.
