# M09.detour-2 — Closing the last window keeps the editor open

**Status:** done on Linux/X11. Windows source-checks with pinned Odin
`dev-2026-11`; Windows execution is unvalidated.

## Behavior

Closing the last window (via `Del`) or deleting the last column (via `Delcol`)
no longer exits the editor. The app stays running with only the global tag, so
the user can still run `Newcol` to open a fresh column and window, or `New` to
open a buffer in a remaining column.

Previously both paths ended in `editor_request_close(.Quit, ...)`, and a running
job left a quit "blocked on jobs" that `Stop` would then complete — so "close
everything" plus "Stop" was another way the whole app died. Removing the implicit
quit removes that too: `Stop` now only cancels jobs and never ends the session on
its own.

The empty workspace is a valid state: `layout.arrange` already renders a lone
global tag for zero columns, the global-tag hit test works without windows, and
the active target is reset so the global tag is editable (active window cleared,
buffer nil, text kind `.Global_Tag`).

Quitting remains explicit: `Exit`, `Ctrl+Q`, `Escape`, or the OS close button.

## Files

- `src/editor.odin` — `editor_enter_empty_state`; `editor_close_active_view`
  closes the last window instead of quitting; `editor_request_close_column`
  enters the empty state instead of quitting when the last column is deleted.

## Tests

`tests/integration/views/x11_harness.py` gained a second scenario: open a blank
buffer, `Del` both windows, assert the editor is still alive at zero views, then
run `Newcol` from the global tag and assert a new column opens.

## Validation

```text
odin run make.odin -file -- view-test --no-config        -> passed (incl. last-window/Newcol scenario)
odin run make.odin -file -- compatibility-test --no-config -> passed (safe per-view close)
odin run make.odin -file -- builtin-test                  -> passed (Delcol/Stop no regression)
odin check src -vet -collection:sokol=third_party/sokol/sokol -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true -> passed
git diff --check                                          -> passed
```

## Notes

`mouse-test` was not run to green: its M07.04 "unknown command is never executed"
scenario (`touch ...` in the global tag) predates M09.13, which now deliberately
routes unknown plain commands to the shell. That failure is pre-existing and
unrelated to this detour; the affected close-path scenario in the same harness
(`button-2 Del`) is covered by `compatibility-test` and `view-test`.

Jobs are still attached to their originating window and are not reaped when that
window closes; `Stop` (global) cancels every running job, so a session can always
be cleaned up from the empty workspace.
