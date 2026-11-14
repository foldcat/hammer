# M04.06 — Dirty-buffer close/quit decisions

Session doc for `src/core/lifecycle/close.odin` and
`tests/unit/lifecycle/close_test.odin` (2026-11-14), implementing the
headless decision layer of SPECS.md §11.6. The application still has no editable
buffer registry or close dialog; this task supplies the shared safety mechanism
those consumers must use.

## One request path

`close_request` handles three scopes through one state machine:

```text
Quit         inspect every dirty named or untitled buffer
Close_View   skip review when another view retains the shared buffer;
             review dirty state when closing its last view
Close_Buffer review the target even when it has no remaining views
```

Every request records a `Close_Origin`: Keyboard, Mouse, Tag_Command, OS_Close,
IPC, or Filesystem. Origin changes reporting only, never the dirty-buffer rules.
Requests carry stable buffer IDs and generations for targeted closes. Duplicate
IDs, missing/stale targets, zero IDs, invalid view counts, invalid enum values,
and overlapping requests are rejected without changing the idle guard.

Inspection is synchronous and bounded. The default total snapshot limit is 4096
buffers (`Close_Options.max_buffers` overrides it), and the pending array owns
only plain ID/generation/revision/resolution values. Allocation failure and limit
errors leave the guard idle with no pending request. The guard is fixed-location,
single-owner, initialized/destroyed explicitly, and not thread-safe.

## Decisions and close authorization

```text
Idle
  -> Ready                 clean request / non-last shared-buffer view
  -> Await_Decision        dirty work requires a choice
       -> Saving           Save All
       -> Reviewing        Review Unsaved
       -> Ready            explicit Discard All
       -> Idle             Cancel
Reviewing
  -> Saving                Save Current
  -> Reviewing/Ready       explicit Discard Current
  -> Idle                  Cancel
Saving
  -> Saving/Ready          validated successful save(s)
  -> Idle                  Cancel
Ready
  -> Idle                  close_finish after authorized actions
```

`Ready` is the only state in which `close_finish` succeeds. The caller executes
actual saves, closes, persistent-state flushing, and service shutdown; the guard
never mutates text, dirty flags, roots, views, or buffers itself. `close_pending`
exposes the borrowed snapshot and each buffer's `Unresolved`, `Saved`, or
`Discarded` resolution until the request is reset. Discard therefore requires an
explicit decision; cancel never becomes close authorization.

Save completions are accepted sequentially for the current pending buffer only.
`close_save_succeeded` validates stable ID, generation, source revision, and
current revision. Both revisions must equal the captured revision, so a stale
result, out-of-order completion, or edit arriving while a save runs cannot
authorize a close. Save-time formatting must complete before the review snapshot.
Cancel resets the request, and late completions are rejected.

Save failures and canceled Save As cannot call the success acknowledgment and
therefore cannot reach Ready. M04.07 adds their explicit error/review behavior;
this task does not claim a save-failure UI. Running-job decisions remain separate
(M09.08). `App` still owns fatal-error and process-phase transitions; a quit
consumer maps guard Cancel to `app_cancel_quit` and Ready to its flush/shutdown
path. The current Sokol demo has no editable document buffers, and its OS-close
comment now records the required future guard wiring.

## Tests and validation

Eight tests expand `tests/unit/lifecycle` from 5 to 13. They cover:

- All six origins reaching the same dirty review and Cancel behavior.
- Clean close/quit, shared views, last-view close, direct buffer close, and
  untitled dirty work.
- Save All ordering, ID/generation/source/current-revision conflicts, and final
  Saved resolutions.
- Per-buffer Review Unsaved with mixed Discarded/Saved outcomes.
- Explicit Discard All, no cancel-as-authorization, and gated `close_finish`.
- Cancellation after a partial Save All, late-result rejection, and clean reuse.
- Invalid input, duplicate/missing/stale targets, overlapping requests, invalid
  decisions, total snapshot limits, and zero/partially initialized cleanup.
- Fixed-arena allocation failure: atomic rejection, no retained pending state,
  and successful processing of a subsequent smaller request.

```text
odin check src/core/lifecycle -no-entry-point -vet -collection:hammer=src
    -> clean
odin check src/core/lifecycle -no-entry-point -vet -target:windows_amd64
    -collection:hammer=src                                 -> clean
odin test tests/unit/lifecycle -vet -collection:hammer=src -> 13/13, leak-free
same targeted command, 20-run loop                         -> 13/13 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 13/13, leak-free
odin run make.odin -file -- test                           -> 18 packages,
    236 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                             -> exit 0, clean shutdown
```

## Traps found

1. The pinned Odin dynamic-array `delete` overload does not take an allocator;
   the array header retains its creation allocator. Slice/data allocations still
   use explicit allocator arguments where supported.
2. Request inclusion must use the new request's kind, not the idle guard's old
   request value while computing the required capture size.
3. Source-revision validation alone does not reject an edit made during an
   asynchronous save. The completion's current revision must also match.

## Platform status and limits

- **Linux:** all decision paths, error/limits/atomicity tests, repeated and
  single-threaded allocator checks, full suite, both builds, and app smoke pass.
- **Windows:** `windows_amd64` cross-check passes; no Windows runtime/UI test was
  performed.
- **Integration:** no real dialog, editable buffer registry, IPC server, or
  filesystem projection exists yet. Those consumers must call this guard rather
  than implementing independent close policies.
- **Failure handling:** actual save failures and Save As cancellation remain
  blocked by the absence of a success acknowledgment, but their reporting and
  retry decisions are M04.07, not a completed UI feature here.

## Next task

M04.07 — save-failure exit blocking: report failed saves and canceled Save As,
preserve the editable dirty buffer, and keep close/quit blocked until a
successful retry, explicit discard, or cancellation.
