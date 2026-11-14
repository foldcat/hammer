# M04.08 — Kill-at-random-point recovery tests

Session doc for `tests/integration/recovery/main.odin`,
`tests/integration/recovery/kill_harness.py`, and the `recovery-test` target in
`make.odin` (2026-11-14). This adds real child-process SIGKILL coverage for the
M04.01–M04.03 journal/checkpoint/rotation/discovery primitives (SPECS.md
§11.3–§11.5 and the isolated-test rules).

## Synchronized exact-point writer

The purpose-built Odin helper has `write` and `verify` modes. `write` uses the
real journal APIs with `.Sync` flush behavior and hooks for every real write,
sync, close, and remove. It creates this bounded workload:

```text
generation 0: initial journal + 3 records
rotate 0 -> 1: full snapshot + empty generation-1 journal
generation 1: 2 records
rotate 1 -> 2: full snapshot + empty generation-2 journal
generation 2: 2 records + close
```

After each actual OS operation succeeds, the hook writes `POINT <n> <operation>`
to stdout and blocks for a one-byte acknowledgment from the external controller.
The controller acknowledges ordinary points or sends SIGKILL without an
acknowledgment at the selected point. The child cannot race ahead to a later
operation, so each boundary is tested exactly rather than approximately.

There are 62 points covering partial journal headers, each record section and
sync, checkpoint identity/snapshot/checksum/sync/close, old-writer close, and old
file cleanup. The initial open itself has no hook; kills begin with its first
header write. A normal completion and calibration run verify the final state and
bound the finite point count.

## External controller and isolation

`kill_harness.py` uses no shell and starts only the explicitly built helper. It
owns a five-second timeout for every protocol wait and verifier invocation,
SIGKILL and process reaping, pipe cleanup, and unique system-temp sandboxes.
Only the direct child is killed; the workload starts no grandchildren. Every
case uses a fresh sandbox. Success removes it; failures preserve and print its
path for diagnosis.

The default run shuffles all 62 points with seed `0x0408`, then adds 12 seeded
random repetitions. Additional validation used seeds 1 and `0xdeadbeef` with 24
random repetitions each. The controller requires all three generations and at
least one torn tail to be covered, so a passing run cannot silently skip
interrupted rotation or verified-prefix cases.

## Independent recovery verification

After each kill, a new helper process runs the real non-destructive
`journal.discover` implementation and checks:

- Recovered generation is one of the scheduled generations.
- Original path and SHA-256 base identity match.
- Generation zero is journal-only; later generations have the exact scheduled
  checkpoint snapshot.
- Journal replay is `Complete` or `Torn_Record`, never a fabricated later state.
- Every recovered payload has its expected contiguous sequence and exact bytes,
  bounded by that generation's planned record count.

The first two operation points can leave no valid initial journal, so
`NO_RECOVERY` is valid only for that early state. Every later kill must select a
usable generation. A complete old pair remains usable while a new checkpoint is
incomplete; once a new pair is complete, discovery may select it even if old
cleanup was interrupted. No recovery evidence is modified by verification.

## Validation run

```text
odin check tests/integration/recovery -no-entry-point -vet -collection:hammer=src
    -> clean
odin check tests/integration/recovery -no-entry-point -vet -target:windows_amd64
    -collection:hammer=src                                  -> clean
odin run make.odin -file -- recovery-test
    -> PASS: 62 exact points + 12 random; 71 recovered,
       3 before initial validity, 17 torn tails,
       generations={0:28, 1:27, 2:16}; seed=1032
python3 tests/integration/recovery/kill_harness.py
    --binary build/recovery_kill_test --seed 1 --random-runs 24
    -> PASS: 62 exact points + 24 random; 84 recovered,
       2 before initial validity, 21 torn tails,
       generations={0:27, 1:33, 2:24}
same command --seed 0xdeadbeef --random-runs 24
    -> PASS: 62 exact points + 24 random; 83 recovered,
       3 before initial validity, 20 torn tails,
       generations={0:33, 1:31, 2:19}
odin run make.odin -file -- test                            -> 18 packages,
    242 tests, exit 0, leak-free
odin run make.odin -file -- build                           -> exit 0
odin run make.odin -file -- build --release                 -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                              -> exit 0, clean shutdown
```

`make recovery-test` builds the helper as the gitignored
`build/recovery_kill_test` and runs the controller with inherited stdio. The
fast `make test` unit target is unchanged; process-kill integration is an
explicit additional target. Python 3 is required for this controller and was
confirmed as Python 3.14.10 in the validation environment.

## Traps found

1. Sending SIGKILL immediately after a progress line is racy: the child may
   complete later operations before the parent is scheduled. The acknowledgment
   round trip is necessary for exact point coverage.
2. Hooks must report after the real operation succeeds. Reporting before the
   operation would test a different state and could hide a completed write.
3. Calibration failures need the same artifact-preservation policy as kill
   cases; unconditional temporary-directory cleanup would discard the evidence.
4. Untyped string constants need an explicit `string(...)` conversion before the
   repository's `transmute([]byte)` idiom on the pinned Odin.

## Platform status and limits

- **Linux/POSIX:** synchronized SIGKILL, exact operation boundaries, random
  repetitions, torn-prefix recovery, interrupted rotation/fallback, normal
  completion, and verifier behavior pass with real isolated files.
- **Windows:** the Odin helper cross-checks for `windows_amd64`; the POSIX
  SIGKILL controller was not run and no Windows process-termination behavior is
  claimed.
- **Durability:** this is process-kill testing at operation boundaries, not
  arbitrary instruction interruption, machine power loss, disk/media failure,
  directory-entry synchronization, or proof of zero data loss. Records written
  but not yet synced are recovered according to the on-disk prefix; durability
  acknowledgments retain the journal's explicit sync contract.
- **Integration:** payloads are deliberately opaque test records. Full editor
  buffer/session restoration and transaction-level UI integration remain later
  consumers; this task validates the storage recovery primitives themselves.

## Next task

M05.01 — bind and pin font/shaping/Unicode libraries, with pinned API/version
checks and honest platform validation.
