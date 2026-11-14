# M04.04 — Stale-session/lock detection

Session doc for `src/core/journal/lock*.odin` (2026-11-14): nonblocking,
OS-backed recovery-session locks (SPECS.md §11.3).

## Authoritative lock, diagnostic identity

The operating-system lock is the only authority for active/stale takeover. PID,
heartbeat age, and metadata contents are never used to break a lock. This avoids
PID reuse, stale-clock, and permission-unknown failure modes.

- Linux uses `flock(EX|NB)` and `flock(UN)`.
- Windows uses nonblocking exclusive `LockFileEx` / `UnlockFileEx` on byte zero.
- The handle stays open for the entire session. Process death releases the OS
  lock even though the file remains.
- Lock files are reused rather than deleted. This prevents the classic race where
  one process locks an old inode while another creates and locks a replacement.

The fixed-size 68-byte lock record has magic, format version, exact length,
PID, session ID, process-instance ID, creation/heartbeat timestamps, reserved
zeroes, and CRC32. Session and instance IDs must be nonzero. Metadata is written
and synced only after lock acquisition. Torn, oversized, unknown-version, or
checksum-invalid records yield `previous_valid=false`; they never override the
OS state.

`Acquire_Result` distinguishes `Acquired_New`, `Acquired_Stale`, and `Active`.
An active conflict returns no owned lock and may include the previous instance's
valid metadata. Successful stale acquisition replaces the record. Heartbeats
refresh only diagnostic metadata; the held handle, not a heartbeat timeout,
keeps the session active. `lock_release` unlocks and closes idempotently and
leaves the stale file for safe reuse.

This is a cooperative advisory lock for Hammer instances using the same trusted
recovery directory, not protection against unrelated non-cooperating writers.

## Tests and validation

Four new tests expand the journal suite from 29 to 33: real new/active/stale
transitions using independent open handles, process/session metadata, heartbeat
visibility, corrupt metadata during an active lock, stale corrupt takeover after
release, oversized-record truncation to the bounded format, invalid input,
missing-parent I/O, idempotent release, and lock-file persistence. Every test
uses a unique temporary directory and no real session files or processes.

```text
odin check src/core/journal -no-entry-point -vet          -> clean
odin check src/core/journal -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/journal -vet -collection:hammer=src  -> 33/33,
    leak-free (memory tracking enabled)
same targeted command, 20-run loop                         -> 33/33 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 33/33
odin run make.odin -file -- test                           -> 18 packages,
    222 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
```

## Traps found

1. PID liveness/start-time probing is unnecessary and less reliable once the OS
   lock itself can prove liveness and release on death.
2. Deleting lock files on release permits inode-replacement races. Persistent
   lock files plus metadata refresh avoid that path entirely.
3. Existing oversized records require truncation before rewriting; an offset-zero
   write alone would leave trailing bytes and make the next record invalid.
4. An explicit unlock error still requires close, because close releases the OS
   lock. Release resets ownership before reporting either error.
5. Odin does not permit `:=` when any returned variable is already declared in
   the same scope; repeated acquisition tests use distinct error variables or
   assignment after all destinations are declared.

## Platform status and limits

- **Linux:** real contention, stale takeover, corruption, bounds, and cleanup are
  tested, including repeated and single-threaded allocator checks.
- **Windows:** the LockFileEx adapter cross-checks for `windows_amd64`; runtime
  locking and error mappings were not exercised under Windows/Wine.
- **Crash coverage:** OS release on process death follows the platform contract,
  but no child-process kill test was run here; randomized recovery kills are
  M04.08. Network-filesystem lock semantics are not claimed.
- **Integration:** no product session startup or UI conflict prompt is wired yet;
  the caller chooses the explicit trusted lock path and unique instance IDs.

## Next task

M04.05 — persist undo transactions and branches: serialize transaction
operations and undo-tree node/branch identity with explicit versions and bounds,
store them in journal records, and reconstruct valid-prefix history without
mutating the current document outside the transaction owner.
