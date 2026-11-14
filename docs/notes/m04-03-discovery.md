# M04.03 — Crash recovery discovery

Session doc for `src/core/journal/discovery.odin` (2026-11-14): bounded,
read-only selection of usable recovery generations (SPECS.md §11.3–§11.4).

## Scan and selection contract

`discover` scans one explicit checkpoint/journal directory without recursion.
Only regular files with canonical `checkpoint-%06d.bin` or `journal-%06d.bin`
names are candidates; larger generations use their full unpadded decimal form.
Malformed names, unrelated files, directories, and symlinks are ignored. The
scan uses Odin's streaming directory iterator rather than an unbounded
read-all operation. The default entry bound is 1024 and includes unrelated
entries; exceeding it is a `.Resource_Limit` error.

Candidates are considered from highest to lowest generation:

- A valid checkpoint+journal pair must agree on the filename generation and all
  embedded file/base/session/process identity fields. A torn tail contributes
  only its verified record prefix.
- A complete checkpoint without a journal is recoverable with an empty tail.
- A journal without a checkpoint is independently recoverable only at generation
  0, where records start from original base content. Later orphaned journals are
  reported as `Missing_Checkpoint`, never replayed onto an unknown checkpoint.
- If both generation files exist but either is unreadable/invalid or their
  metadata differs, that generation is skipped and discovery falls back to an
  older valid one. A valid generation-0 journal can still be used when its
  optional checkpoint is corrupt.

The selected `Discovery` contains owned checkpoint/tail data and selected paths.
`issues` reports invalid checkpoints, invalid journals, missing checkpoints, and
generation mismatches without failing an otherwise usable scan. Empty discovery
with issues is a normal result; directory/iterator and allocation failures are
explicit errors. `discovery_destroy` releases all owned storage with its creating
allocator. Discovery never removes, renames, truncates, or overwrites evidence.

Current disk identity is deliberately a separate decision: after discovery the
caller must still use `validate_identity` before applying recovered transactions.
No stale-process or lock decision is made here.

## Tests and validation

Six new tests expand the journal suite from 23 to 29: highest-valid selection,
corrupt-latest and mismatched-generation fallback, torn-tail valid-prefix
recovery, initial journal-only recovery, later orphan reporting,
checkpoint-only recovery, empty directories, entry limits, unrelated files,
evidence preservation, and Linux symlink rejection. All paths live in unique
system-temp sandboxes.

```text
odin check src/core/journal -no-entry-point -vet          -> clean
odin check src/core/journal -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/journal -vet -collection:hammer=src  -> 29/29,
    leak-free (memory tracking enabled)
same targeted command, 20-run loop                         -> 29/29 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 29/29
odin run make.odin -file -- test                           -> 18 packages,
    218 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
```

## Traps found

1. Initial generation-0 journals need a journal-only recovery path; requiring a
   checkpoint would discard all work written before the first rotation.
2. Later journal-only files are not safe to replay from original base content,
   because their checkpoint already contains earlier transactions.
3. Discovery must verify both filename and embedded generation. Matching only
   checkpoint and tail metadata could still select a misnamed generation.
4. Iterator `File_Info` values are reused and borrowed. Candidate paths are cloned
   before the next directory entry and temporary candidate strings are released
   with the discovery allocator.
5. Expected corrupt recovery data is an issue, not an allocation/scan failure;
   this distinction allows bounded fallback instead of aborting at the newest
   damaged file.

## Platform status and limits

- **Linux:** real isolated directory scans, corruption/fallback/torn-tail tests,
  symlink rejection, repeated/single-threaded leak checks, full suite, builds,
  and application smoke all pass.
- **Windows:** `windows_amd64` cross-check passes. Directory iteration and file
  type behavior were not run under Windows/Wine in this session; symlink behavior
  was tested only on Linux.
- **Integration:** discovery covers one buffer/generation directory, not a
  recursive multi-buffer session root. There is no product UI consumer, lock
  acquisition, transaction application, random process-kill test, or power-loss
  claim.

## Next task

M04.04 — stale-session/lock detection: define a bounded process-instance/lock
record using more than PID alone, acquire locks without clobbering active
recovery sessions, classify stale/unknown state conservatively, and test stale
cleanup and active-session conflicts in isolated directories.
