# M04.02 — Periodic checkpointing and rotation

Session doc for `src/core/journal/checkpoint.odin` and `rotation.odin`
(2026-11-14): full snapshots, bounded rotation triggers, and crash-safe
checkpoint-plus-tail generations (SPECS.md §11.3–§11.5).

## Generation format

Journal format 2 uses the two former reserved header words for a 64-bit
generation ID. Each journal generation restarts record sequence numbers at 1.
The original path, platform file identity/size/mtime, original base-content
hash, encoding metadata, session, and process identity remain unchanged across
rotations; only generation and creation timestamp advance.

```text
Checkpoint v1:
  fixed header (64 bytes)
  embedded complete journal header (identity + path + header CRC32)
  snapshot bytes
  whole-checkpoint CRC32
```

The fixed checkpoint header carries the embedded-header length, snapshot length,
and SHA-256 snapshot hash. The whole-file checksum includes every embedded
header/path byte and the snapshot. Checkpoints are all-or-nothing: exact file
length, both checksums, and the snapshot hash must validate. There is no partial
checkpoint replay.

`recover_generation` requires identical identity/session/generation metadata in
the checkpoint and tail journal, then returns the owned snapshot and the tail's
verified record prefix. It does not interpret or apply opaque transactions.
Original disk identity validation continues to use the retained original header,
not the hash of an unsaved checkpoint snapshot.

## Periodic policy and rotation

`rotation_due` is a synchronous caller-evaluated policy with no scheduler or
worker. Defaults are 30 seconds, 8 MiB of journal data, or 4096 records; all are
bounded/configurable, and negative policy fields disable rotation.

`rotate` performs this order:

1. Require an open, unpoisoned writer and a strictly greater generation.
2. Exclusively create and complete the new journal.
3. Exclusively write, optionally sync, and close the matching checkpoint.
4. Close the old writer and atomically transfer the new Writer value to the
   caller.
5. Remove the old checkpoint and journal.

Before step 4, failure leaves the old writer unchanged and usable; partial new
files are cleaned up on ordinary error returns. After the new pair is complete,
old-close or old-file cleanup failure returns `rotated=true` together with the
error, and the caller continues with the new writer. Cleanup failure never rolls
back or deletes the new generation. A process interruption can leave an old and
new pair, or an incomplete new file, but never requires deleting the old pair
before a complete new pair exists. Normal successful rotation retains one pair;
an interrupted/failed cleanup can retain two and reports that condition.

Checkpoint and journal creation remain exclusive and user-read/write only.
Directory-entry synchronization and power-loss atomicity are not claimed.

## Tests and validation

Nine new tests expand `tests/unit/journal` from 14 to 23. They cover checkpoint
binary/metadata round trips, checkpoint-plus-tail reconstruction, original
identity validation, generation mismatch, corruption/truncation/trailing data,
path/file limits, exclusive creation, time/size/count triggers, non-monotonic
rotation rejection, successful old-generation removal, pre-publication write
failure with continued old-writer appends, old-file cleanup failure with both
generations recoverable, old-close failure after publication, and checkpoint
sync failure cleanup. All tests use unique system-temp sandboxes and injected
operation failures; none touch real recovery directories.

```text
odin check src/core/journal -no-entry-point -vet          -> clean
odin check src/core/journal -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/journal -vet -collection:hammer=src  -> 23/23,
    leak-free (memory tracking enabled)
same targeted command, 20-run loop                         -> 23/23 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 23/23
odin run make.odin -file -- test                           -> 18 packages,
    212 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
```

## Traps found

1. A checkpoint must retain original disk/base identity separately from the
   unsaved snapshot hash; otherwise post-checkpoint disk validation would compare
   unrelated content or silently weaken identity checks.
2. Checkpoint and tail filenames alone are not a sufficient association inside
   the recovery API. Both files carry and verify the same generation and complete
   identity metadata.
3. Multi-file publication has no single portable atomic operation. Publication
   order and explicit `rotated` status preserve a recoverable generation instead
   of pretending checkpoint+journal replacement is atomic.
4. Close/remove fault hooks must run at every actual cleanup call. A close hook
   closes the real handle before reporting its injected error, so rotation never
   retries a potentially closed descriptor.
5. The pinned Odin rejects direct iteration over a fresh slice literal in
   `for path in []string{...}`; rotation names the two-element slice first.

## Platform status and limits

- **Linux:** checkpoint/rotation behavior and failure paths tested with real
  isolated files, repeated/single-threaded allocator checks, full core suite,
  both builds, and application smoke.
- **Windows:** `windows_amd64` cross-check passes; runtime rename/delete/sharing
  and real filesystem behavior were not exercised.
- **Crash coverage:** deterministic operation interruption is tested, not random
  process kills (M04.08) or actual power loss. Directory sync remains open.
- **Integration:** no background scheduler, discovery, stale-lock handling, or
  transaction application is included. The caller supplies immutable snapshot
  bytes and unique generation paths.

## Next task

M04.03 — crash recovery discovery: scan an explicit isolated recovery root with
bounded entries, ignore incomplete/mismatched generations, select the highest
fully valid checkpoint-plus-tail pair, and expose incomplete journals without
overwriting or deleting recovery evidence. Stale-session/lock decisions remain
M04.04.
