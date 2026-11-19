# M08.06 — Cancellable snapshot-based Edit execution

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Snapshot worker and ownership

`src/core/edit/runner.odin` adds a bounded, single-job `Runner`. Submission
copies the parsed program and the full current document into a private growing
arena, then executes on one worker thread. The worker never receives or mutates
the live document, selection, buffer history, view, or editor layout. The
existing synchronous `execute` entry point remains available for headless and
unit use.

Each result carries the stable buffer ID, buffer generation, source revision,
request ID, and undo grouping key. A result contains transaction batches and
final selection/regex-history snapshots. Batches borrow worker-document storage
and remain valid until `runner_release`; result errors are cloned into the
caller's allocator by `apply_result`. Polling is nonblocking and uses thread
completion as the synchronization edge. Release joins/destroys the thread,
destroys the snapshot with its worker allocator in scope, and calls `free_all`
before destroying the job arena. Shutdown requests cancellation and joins the
worker before releasing any snapshot state.

Only one Edit job can be active in the editor. A second submission returns
`.Resource_Limit` rather than growing a queue.

## Cancellation and result application

An atomic cancellation flag is checked between Edit commands, during address
evaluation, between successive matches and replacement construction, and inside
the native regex VM's position/thread loops. Cancellation discards all worker
batches and leaves live text, selection, and regex history unchanged.

`apply_result` validates target ID, generation, request ID, and source revision
before any mutation. Stale results apply nothing. Valid batches replay in
command order through `txn.doc_apply` with source `.Edit` and one undo group. As
with synchronous execution, an ordinary runtime error may return successful
prefix transactions; cancellation and revision conflicts do not. Selection-only
commands also apply without creating a transaction.

The product `Edit` handler in `src/command_ui.odin` now submits every invocation
to the runner. The frame loop polls and applies completions, transforms other
views once per applied transaction, refreshes dirty tags, and reports worker or
revision errors. Escape requests cancellation when an Edit is active and keeps
its existing quit behavior otherwise. Buffer/window removal is safe because the
worker owns its snapshot; a result whose originating window or buffer is gone is
rejected.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/address -vet -collection:hammer=src
    -> 28/28 tests passed, allocator tracking clean
odin test tests/unit/edit -vet -collection:hammer=src
    -> 22/22 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 425 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- edit-test --no-config
    -> asynchronous Edit change/delete/move/substitution, save, and Undo passed on X11
odin run make.odin -file -- mouse-test --no-config
    -> all existing mouse/modifier/chord checks passed
odin run make.odin -file -- compatibility-test --no-config
    -> all seven integrated compatibility stages passed
```

New unit coverage exercises worker result metadata, bounded admission, snapshot
replay and grouped Undo, stale request/revision rejection, cancellation without
mutation, direct regex/address cancellation, and successful-prefix replay on a
runtime error. The X11 harness waits for actual worker completion before saving.

No native Windows/Wine run, direct Acme differential run, or real-X11 long-edit
Escape cancellation scenario was performed. Unit cancellation exercises the
runner and cancellation API; the product Escape path is source-checked but not
separately exercised with a long-running UI job. Differential fixtures remain
M08.08.

## Next task

M08.07 should add atomic multi-buffer validation where an Edit operation spans
buffers: validate every target generation and revision before applying any
batch, and prove that one stale target causes no edits on any target.
