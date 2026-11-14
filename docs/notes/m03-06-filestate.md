# M03.06 — Disk-change conflict detection

Session doc for `src/core/filestate` (2026-11-14): synchronous disk observation
and clean/dirty conflict policy over M03.01 checkpoints and M03.02 handle-based
capture (SPECS.md §11.1–§11.2).

## Design

```text
Change       Unchanged | Modified | Replaced | Missing
Action       None | Offer_Reload | Resolve_Conflict
Observation  change + action + allowed conflict choices + observed Capture
             + identity_verified
observe_file path + expected Capture + dirty -> Observation / error
classify     pure expected/observed Capture comparison
```

- **Handle-based observation.** `observe_file` reuses `fileload.capture_file`;
  identity and version therefore come from the same opened file. Deletion is a
  normal `.Missing` result. Permission, stat, and unsupported-file errors remain
  errors and are never misreported as unchanged.
- **Clean buffers.** Modified/replaced destinations produce `.Offer_Reload`.
  Missing destinations do not offer reload into nonexistent content. Unchanged
  destinations require no action. Actual reload and configuration-driven
  automatic reload remain caller responsibilities.
- **Dirty buffers.** Modified/replaced destinations produce `.Resolve_Conflict`
  with explicit Reload-and-Discard, Keep Local, Save As, Compare, and Explicit
  Overwrite choices. Missing destinations offer Keep Local and Save As; there is
  no in-place overwrite or reload of a missing file. The package does not execute
  any choice or mutate the buffer, dirty state, checkpoint, or filesystem.
- **Identity-less filesystems.** `fileid.stamp_identity_verified` makes degraded
  identity explicit. Unchanged size/mtime without usable IDs does not create a
  spurious polling conflict, but Observation reports `identity_verified=false`.
  Normal filesave `.Unchanged` now rejects that condition. The explicit
  `allow_unverified_identity` option compares size/mtime only; verified IDs still
  require exact identity and version equality. Explicit overwrite remains a
  separate `.Allow_External_Changes` decision.
- **Ownership and concurrency.** Observations and captures are plain values.
  Only capture errors allocate, using the caller allocator and `errs.destroy`.
  Polling is synchronous, bounded to one open/stat/close, and introduces no
  worker, queue, cache, file-notification subscription, or background mutation.
  Revisioned buffer integration belongs to the later buffer/UI consumer.

## Validation run

```text
odin check src/core/filestate -no-entry-point -vet         -> clean
odin check src/core/filestate -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/filestate -vet -collection:hammer=src -> 6/6, leak-free
same targeted command, 10-run loop                         -> 6/6 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 6/6
odin test tests/unit/filesave -vet -collection:hammer=src -define:ODIN_TEST_THREADS=1
                                                            -> 14/14
odin run make.odin -file -- test                           -> 17 packages,
    183 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
Windows -no-crt consumer (build/m03-06-consumer, generated)
    cross-built for windows_amd64 and run under Wine: unchanged, modified,
    atomically replaced, and missing observations — "filestate M03.06 consumer:
    ok", exit 0
```

Six filestate tests cover unchanged clean/dirty behavior, clean reload offers,
all dirty conflict actions, missing-file choices, identity-less degradation,
real in-place modification/atomic replacement/deletion, and invalid-path /
non-regular-file errors. A fourteenth filesave test proves unverified identity
is rejected without touching disk and succeeds only with explicit permission.

## Traps found

1. **Composite literals in a range clause need a named value** in the pinned
   parser: both `for x in []bool{...}` and the fixed-array form were rejected;
   assigning the cases first is clear and portable within this Odin version.
2. **Unverified save must relax identity equality, not all equality**: when one
   ID is `.None`, `stamp_equal` is false even with matching size/mtime. Explicit
   unverified mode uses `version_equal`; verified mode retains `stamp_equal`.

## Platform status and limits

- **Linux:** implemented and tested with real in-place and atomic-replace
  filesystem changes, full suite, builds, and Xvfb smoke.
- **Windows:** implemented and tested under Wine with a `-no-crt` consumer;
  real Windows filesystems remain unvalidated.
- **Detection limits:** size/mtime/ID cannot detect same-size/same-mtime edits;
  `.None` identities require the explicit degraded policy above. This slice
  polls on demand and does not claim OS notification, canonical-path
  resolution, case-sensitivity probing, or automatic reload.
- **Product integration:** no buffer registry/UI consumer yet. Dirty-state
  application, revision validation, reload execution, and conflict dialogs are
  later buffer/M04/M06/M07 integration work.

## Next task

M03.07 — failure-injection tests for save: inject short writes, disk-full,
flush/close/rename failures, and post-publication capture failure; verify the
original destination, dirty/checkpoint contract, cleanup, and `replaced` flag
at every point without filling a real disk.
