# M03.07 — Failure-injection tests for save

Session doc for `src/core/filesave` (2026-11-14): deterministic operation-level
fault injection around the M03.05 temporary-write/replace state machine
(SPECS.md §11.1 and §22.5).

## Design

`Operation_Hooks` is an optional borrowed field on `filesave.Options`. Each
operation field may be nil (the real OS operation) or supply a synchronous
adapter with a caller-owned `data` pointer:

```text
create_temp -> write -> sync -> chmod -> close -> recheck
             -> link/rename -> remove -> capture
```

The hooks cover temporary creation, snapshot writes, sync, permission changes,
close, removal, hard-link publication, rename replacement, and checkpoint
capture. The real path remains the zero-value default. Hooks are never retained
and must preserve the real operation's ownership/handle contracts. No global
fault state, process-wide filesystem override, thread, or test-only build flag
is introduced.

## Verified failure contract

- **Before publication:** create, write/disk-full class, zero-write, sync,
  chmod, close, initial/recheck capture, link, and rename failures return an
  error with `replaced=false` and no new checkpoint. The original destination
  remains byte-exact and ordinary cleanup leaves only the original directory
  entry. Close injection closes the real handle before reporting failure.
- **Short writes:** one-byte successful writes are looped until the complete
  snapshot is present; they are not mistaken for completion.
- **After publication:** final capture failure after rename or new-file link
  returns `replaced=true`, preserves the newly published content, and reports
  no unverified checkpoint. Injected temporary-link cleanup failure likewise
  reports `replaced=true`; the deliberately failed cleanup leaves the extra
  temporary link for diagnosis rather than pretending cleanup succeeded.
- **Dirty state:** the save API still has no dirty-state pointer or mutation.
  No injected result can clear editor dirty state; the caller may apply a fresh
  checkpoint only after a successful, revision-matching publication.

Tests use unique system-temp sandboxes and injected errors. They never fill a
real disk, change real user documents, or require elevated permissions.

## Validation run

```text
odin check src/core/filesave -no-entry-point -vet          -> clean
odin check src/core/filesave -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/filesave -vet -collection:hammer=src  -> 20/20,
    leak-free (memory tracking enabled)
same targeted command, 20-run loop                         -> 20/20 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 20/20
odin run make.odin -file -- test                           -> 17 packages,
    189 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
Windows -no-crt consumer (build/m03-07-consumer, generated)
    cross-built for windows_amd64 and run under Wine: injected write failure,
    rename failure, and final capture failure; original preservation/temp
    cleanup and post-replacement reporting — exit 0
```

Six new tests expand filesave from 14 to 20: the nine-case pre-publication
matrix, partial writes, new-file link failure, post-rename capture failure,
post-new-file capture failure, and post-publication cleanup failure.

## Traps found

1. **Fault hooks must live at each actual OS call**, including deferred cleanup
   and both checkpoint rechecks; wrapping only the top-level save would not test
   the real stage transitions.
2. **A close-failure hook must define handle state**: the test closes the real
   handle before returning the injected error, matching save's no-retry close
   policy and allowing Windows temporary-file removal to proceed.
3. **Post-publication failures cannot use the ordinary untouched-file
   assertion**: their required assertion is new content plus `replaced=true`,
   with no fabricated checkpoint.

## Platform status and limits

- **Linux:** injected matrix, repeated/single-threaded leak checks, full suite,
  builds, and Xvfb smoke all pass.
- **Windows:** cross-check plus Wine runtime fault consumer pass; real Windows
  and native filesystem failure behavior remain unvalidated.
- **Crash/power loss:** these are deterministic operation failures, not random
  process-kill recovery tests. Actual power-loss durability, directory-entry
  sync, and M04 journal recovery are not proven by this suite.

## Next task

M04.01 — versioned checksummed journal: define explicit bounded records,
length/version/sequence/checksum validation, valid-prefix replay, and torn-final
record handling in isolated recovery storage.
