# M10.06 detour — output and directory windows close without a save guard

**Status:** done on Linux/X11. This was a requested detour and does not replace
the active M10.07 task.

## Behavior change

`Del` on `+Errors` (or a directory listing) and quit no longer block with
"unsaved text; close blocked". Only file buffers can be saved, so
`editor_buffer_dirty` in `src/editor.odin` now returns `false` for `.Directory`,
`.Errors`, `.Job_Output`, `.Commands`, `.Jobs`, and `.Terminal` buffers. File
buffers keep the ordinary dirty tracking, so an edited file still blocks
close/quit exactly as before.

This revises M07.07's note, which treated edits to directory and error buffers
as user work that blocks close/quit. Those buffers are regenerable listings and
transcripts, not documents, so protecting their edits from `Del`/quit made them
impossible to close (there is no save path for them). `Get` reloads a directory
listing and discards edits, matching Acme, where only file windows prompt on
close.

## Fix to the directory X11 test

While validating, the `directory-test` was found already broken against the
current source (not by this change): commit `be1627a` ("tagbar behavior") had
renamed the save-error message to "save: non-file windows cannot be saved as
files" and switched the `errors: appended` log from cumulative `end` to
per-append `len(payload)`, but `tests/integration/directory/x11_harness.py` still
asserted the old message and cumulative byte counts. The test now matches the
current message and per-append log, and its final scenario asserts the new
behavior: editing `+Errors` does not block quit.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol   -> passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> passed
odin run make.odin -file -- builtin-test                        -> passed (dirty-file Delcol/Get scenarios still block)
odin run make.odin -file -- directory-test                      -> 6/6 passed (incl. "editing an output window is disposable")
git diff --check                                                 -> passed
```

## Not validated

Windows runtime was not exercised. No new core unit test was added for the
dirty semantics (the close guard itself is unchanged; only the caller's snapshot
computation changed), so the behavior is covered by the X11 directory/builtin
harnesses.
