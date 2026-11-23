# M08.09 — Built-in window/file commands

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows runtime was not exercised.

## Commands

`src/command_ui.odin` registers and implements the six built-ins through the
existing exact-name dispatcher:

- **New** creates an empty buffer with no argument, or opens whitespace-separated
  file/directory arguments in the invoking column. Each path is normalized
  relative to the source buffer where applicable. Creation uses the bounded
  layout, buffer, and view capacities.
- **Newcol** appends a column, initializes its independent tag, creates an empty
  window, and rolls back partial initialization on failure.
- **Zerox** adds another view of the current non-directory buffer. Selection,
  viewport, wrapping, horizontal scroll, and gutter state are copied into the
  new view; text and undo history remain shared. Global-tag invocation uses the
  active window. View-creation failure never destroys the shared buffer.
- **Delcol** captures every distinct buffer in the column and submits the set to
  the lifecycle close guard. Any dirty buffer blocks the entire deletion before
  a view is destroyed. A clean deletion cancels view/tag requests, destroys only
  newly unreferenced buffers, removes the column, and activates a remaining view.
- **Get** reloads the existing path or an explicit argument without changing the
  buffer's file name. Dirty content blocks replacement. File/directory data is
  loaded into temporary ownership first; only a successful load reaches a whole-
  buffer `.Reload` transaction. Same-name reloads update capture/metadata and the
  saved checkpoint. Different-name file reloads remain dirty for a later Put to
  the original path; file-to-directory reloads adopt the normalized directory
  path and directory buffer kind. Failures leave the editable buffer and dirty
  state intact.
- **Putall** visits each buffer once, skipping clean, untitled, directory, error,
  and non-regular-file targets. Dirty existing regular files use the same safe
  save helper as Put, including external-change checks. Failures are reported
  without clearing dirty state, and other buffers continue saving.

The global tag now includes Newcol and Putall; column tags include New and
Delcol. Global window/file command routing prefers the active window over a
stale active-column value.

## Ownership and layout support

Column tags use stable slots keyed by column ID rather than layout indices.
Deleting a middle column therefore cannot relocate or double-free tag documents.
Rendering, mouse targeting, clipboard polling, activation, and destruction all
use the same lookup.

`layout.remove_column` removes a column without relocating any view or text
state. `lifecycle.Close_Kind.Close_Column` is a targetless multi-buffer request
with the same pending/save/discard/cancel machinery as quit. Its dirty set
includes shared buffers because Delcol removes every view in that column.

`editor_open_buffer_in_column` now has an explicit destroy-on-error policy.
Existing newly allocated callers retain the default; Zerox opts out.

## Tests

New layout and lifecycle unit tests cover middle-column removal, remaining
window order/lookup, missing-column deletion, all-buffer dirty review, shared
buffers, clean readiness, cancellation, and invalid target metadata.

`tests/integration/builtins/x11_harness.py` uses a unique filesystem/state
sandbox and real X11 mouse/keyboard dispatch. It covers:

- Newcol and empty/named New.
- Zerox shared editing and one save per buffer.
- Dirty Delcol rejection before any deletion.
- Clean same-name Get, dirty Get rejection, undo back to clean, and successful
  reload afterward.
- Get with another path while retaining the original save destination.
- Putall writing two dirty files exactly once each.
- Clean Delcol and normal shutdown afterward.

`make.odin` adds `builtin-test` for this scenario.

## Validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/layout -vet -collection:hammer=src
    -> 18/18 tests passed
odin test tests/unit/lifecycle -vet -collection:hammer=src
    -> 20/20 tests passed
odin run make.odin -file -- test
    -> all 432 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- builtin-test --no-config
    -> all six built-in scenarios and dirty-safety checks passed on X11
odin run make.odin -file -- layout-test --no-config
odin run make.odin -file -- view-test --no-config
odin run make.odin -file -- tag-test --no-config
odin run make.odin -file -- edit-test --no-config
odin run make.odin -file -- compatibility-test --no-config
odin run make.odin -file -- directory-test --no-config
    -> all six existing X11 harnesses passed
git diff --check
    -> passed
```

No native Windows/Wine runtime, injected product allocation failure, or
asynchronous Get operation was exercised. Get currently loads synchronously and
resets view origins; preserving Acme's line-relative reload viewport is not
claimed. New arguments are whitespace-separated, not shell-quoted.

## Next task

M08.detour-1 should scroll a truncated buffer when right-arrow cursor movement
places the cursor outside the visible horizontal area, with shared hit-test and
render geometry plus focused X11 coverage.
