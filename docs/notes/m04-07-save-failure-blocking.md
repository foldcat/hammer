# M04.07 — Save-failure exit blocking

Session doc for the M04.07 extension to `src/core/lifecycle/close.odin` and
`tests/unit/lifecycle/save_failure_test.odin` (2026-11-14), implementing
SPECS.md §11.6's failed-save and canceled-Save-As requirements over the M04.06
close guard and M03.05/M03.07 save-result contracts.

## Failure state and ownership

`Close_Guard` now has a `Save_Failed` phase between `Saving` and any subsequent
decision. Two APIs enter it for the current pending buffer:

```text
close_save_failed(id, generation, source_revision, current_revision,
                  error, replaced)
close_save_as_canceled(id, generation, source_revision, current_revision)
```

Both require the same stable identity and revision match as a successful save.
Stale, out-of-order, wrong-phase, or edited-during-save results change nothing
and cannot authorize exit. The pending resolution becomes `Failed`, and
`close_finish` continues to reject the request. Neither API touches text, roots,
or dirty state, so the editable buffer remains available for retry/review.

`Save_Failure` records buffer ID, `Operation_Failed` or `Save_As_Canceled`, the
post-publication `replaced` flag, and the owned error cause. Canceled Save As has
no fabricated I/O error. `close_failure` borrows this record for reporting.

`close_save_failed` takes ownership of the supplied `errs.Error` only when the
failure is accepted. A rejected stale/invalid failure remains caller-owned. The
guard destroys an accepted cause on retry, Save As, review, discard, Cancel,
close reset, or guard destruction. Allocator-tracking tests cover accepted and
rejected ownership and destruction with an active failure.

## Decisions after failure

```text
Operation_Failed, replaced=false:
  Retry_Save       return to Saving with Unresolved resolution
  Save_As          deliberately save to a caller-selected destination
  Review_Unsaved   return to per-buffer Save Current/Discard Current
  Discard_Current  explicitly discard this buffer and advance
  Discard_All      explicitly discard every pending buffer
  Cancel           abandon close/quit and clear the request

Operation_Failed, replaced=true:
  Save_As / Discard_Current / Discard_All / Cancel only

Save_As_Canceled:
  Save_As / Review_Unsaved / Discard_Current / Discard_All / Cancel
  (Retry_Save is rejected)
```

A post-publication error means the destination changed but a verified
checkpoint may be unavailable. Blind `Retry_Save` and the indirect
Review-then-Save-Current route are both rejected. The caller must deliberately
choose Save As, explicitly discard, or cancel; it must not interpret the failure
as a clean saved checkpoint. A later successful, revision-matching save is still
required before `Ready`.

All failure exits remain blocked until an explicit decision. Retry/Save As clears
the failure and returns to `Saving`; only `close_save_succeeded` advances the
pending buffer to `Saved`. Discard paths require the same explicit choices as
M04.06. Cancel returns to `Idle`, destroys the diagnostic, and rejects late save
results.

## Tests and validation

Six tests expand `tests/unit/lifecycle` from 13 to 19. They cover:

- Pre-publication I/O failure blocking, borrowed diagnostics, retry, successful
  completion, and cleanup.
- Stale failure identity/revision rejection with caller-retained ownership,
  empty-error rejection, and stale Save As cancellation.
- Canceled Save As blocking, rejected ordinary retry, deliberate Save As, and
  successful completion.
- Post-publication capture failure with `replaced=true`: no blind retry, no
  indirect review retry, no finish, and deliberate Save As recovery.
- Per-buffer discard after a partial Save All, review/discard, Cancel with late
  result rejection, and Discard All directly from failure.
- Guard destruction while an owned failure is active.

```text
odin check src/core/lifecycle -no-entry-point -vet -collection:hammer=src
    -> clean
odin check src/core/lifecycle -no-entry-point -vet -target:windows_amd64
    -collection:hammer=src                                 -> clean
odin test tests/unit/lifecycle -vet -collection:hammer=src -> 19/19, leak-free
same targeted command, 20-run loop                         -> 19/19 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 19/19, leak-free
odin run make.odin -file -- test                           -> 18 packages,
    242 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                             -> exit 0, clean shutdown
```

The M03 filesave suite continues to pass unchanged (20/20 within the full
suite), including real isolated files and injected pre/post-publication faults.
This task tests the close-side composition with owned errors; it does not add a
second filesystem fault injector.

## Traps found

1. Error ownership must be conditional on acceptance. Destroying the supplied
   error on a stale failure would leave the caller with a dangling owner;
   transferring it on success without documenting that rule would double-free.
2. Blocking only the direct Retry decision is insufficient after publication:
   Review Unsaved followed by Save Current would be the same blind retry. That
   indirect route is rejected too.
3. Failure results need the same source/current revision validation as success;
   otherwise an edit made during a failed save could still authorize closing.

## Platform status and limits

- **Linux:** all failure decisions, ownership/error paths, repeated and
  single-threaded allocator checks, full suite, builds, and application smoke
  pass.
- **Windows:** `windows_amd64` cross-check passes; no Windows runtime/UI test was
  performed.
- **Integration:** no actual dialog or editable buffer registry exists yet. The
  product consumer must pass `filesave.Result.replaced`, revision/identity data,
  and owned save errors through these APIs, and must not clear dirty state on
  failure. Running-job decisions remain M09.08.

## Next task

M04.08 — kill-at-random-point recovery tests: purpose-built child processes,
external timeout/cleanup, deterministic kill points, and reconstruction from
checkpoints plus verified journal prefixes without claiming power-loss proof.
