# M04.05 — Persistent undo transactions and branches

Session doc for `src/core/txn/archive.odin`, the revision-0 base-snapshot
support in `txn.odin`, and `tests/unit/txn/archive_test.odin` (2026-11-14).
This implements SPECS.md §8.4 and §11.7 without adding the M14 interactive
history UI or retention manager.

## Archive format and ownership

The undo archive has its own files and retention lifetime; it never rotates or
prunes recovery data. It reuses journal format 2 for the checksummed file
header, bounded records, sync policy, writer poisoning, and verified-prefix
replay. Archive entry payload version 1 uses explicit little-endian fields, not
native struct memory:

```text
Entry (128-byte fixed header):
  version, operation count, transaction ID, parent ID
  base/after revisions, grouping key, timestamp
  before/after selections (offsets, affinity, preferred visual column)
  source, reserved fields
Operation (32-byte fixed header + data):
  kind (insert/delete/replace), reserved fields
  start/end byte offsets, data length, data
```

The transaction ID is also the journal sequence number, so records must be
contiguous and in apply order. Parent IDs reconstruct child arrays in that same
order. Roots and child arrays are not duplicated in the file. Encoding owns its
returned payload; decoding owns its operation/data copies and releases them
with `ops_destroy` using the creating allocator. `Archive_Writer` owns the
underlying journal writer and remains synchronous and single-owner.

`archive_append` rejects non-contiguous IDs, invalid parents, no-op nodes, and
oversized payloads before writing. Journal append/sync failures retain the
existing poisoning semantics. `archive_sync` is required for a durability
acknowledgment when flush policy is `.None`; close alone is not one.

## Replay and base snapshots

`doc_init_from_bytes` adds an explicit revision-0 base snapshot. The base is
copied into the document's chunk store and retained as `initial_root`; it does
not create a synthetic transaction. `doc_check` now validates root-child
before-roots and the current revision-0 root against that snapshot.

`archive_replay` requires the supplied base content's SHA-256 to match the
archive header before applying anything. Each verified entry is decoded with
length/version/enum/reserved-field checks, then reapplied through `doc_apply`
at its recorded parent. Replay validates dense IDs, parent/base/after revision
chains, before-selection agreement, effective operations, post-edit selection
bounds, and matching inner/outer timestamps. It restores the archived IDs,
revisions, timestamps, source, grouping keys, selections, all branches, and
persistent before/after roots. The final active node is the newest valid node.

A torn record, checksum failure, or configured replay-budget stop returns the
journal status and the successfully restored valid prefix. A checksummed but
semantically invalid payload is an error and destroys the partially restored
document rather than silently skipping history. A base-hash mismatch is a
`.Conflict` and leaves the destination uninitialized.

Path/file-stamp validation against reopened disk state is deliberately not
claimed here; M14.05 owns that product-level validation. Persisting an active
position earlier than the newest node is M14.04 branch-selection work. Labels,
checkpoints, arbitrary branch jumps, orphan policy, and history pruning also
remain M14 tasks. No product buffer/session consumer is wired in this slice.

## Tests and validation

Six isolated tests expand `tests/unit/txn` from 21 to 27. They cover:

- Nonempty bases, multi-operation nodes, exact encoded metadata/operation round
  trips, every node snapshot, abandoned branches, grouping, selections, negative
  and positive timestamps, undo/redo, and revision-0 invariants.
- Torn and checksum-corrupt final records restoring only the first two nodes.
- Payload versions, operation counts/kinds, reserved fields, sources, affinities,
  lengths, offsets, trailing data, no-op nodes, invalid parents, and timestamp
  disagreement, with allocator leak detection.
- Base-hash conflicts, record/payload limits, writer size/sequence/no-op errors,
  and empty-prefix restoration.
- A deterministic 120-step randomized apply/undo/redo history, comparing every
  encoded node and every restored snapshot after replay.

All archive files use unique system-temp sandboxes. No real history, recovery,
configuration, document, or clipboard location is touched.

```text
odin check src/core/txn -no-entry-point -vet -collection:hammer=src
    -> clean
odin check src/core/txn -no-entry-point -vet -target:windows_amd64
    -collection:hammer=src                            -> clean
odin test tests/unit/txn -vet -collection:hammer=src -> 27/27, leak-free
same targeted command, 20-run loop                    -> 27/27 each
same targeted command -define:ODIN_TEST_THREADS=1     -> 27/27, leak-free
odin run make.odin -file -- test                      -> 18 packages,
    228 tests, exit 0, leak-free
odin run make.odin -file -- build                     -> exit 0
odin run make.odin -file -- build --release           -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                        -> exit 0, clean shutdown
```

## Traps found

1. Named-result cleanup cannot rely on a result that an error return resets to
   `{}`. Decoding uses a separate local owner and transfers it only on success;
   the leak test caught the original lost operation arrays.
2. A decoded no-op must be rejected before `doc_apply`: a no-op creates no log
   node, so indexing the supposedly appended node would be invalid.
3. A randomized undo/redo driver must choose an available direction. “Either
   direction exists” does not imply the randomly selected direction exists.

## Platform status and limits

- **Linux:** archive round trips, malformed input, verified prefixes, limits,
  repeated/single-threaded allocator checks, the full core suite, both builds,
  and application smoke were tested.
- **Windows:** `windows_amd64` cross-check passes. No Windows archive runtime or
  real-filesystem behavior was exercised.
- **Durability:** journal sync and torn-prefix behavior are implemented and
  tested, but random process kills (M04.08), power loss, and directory-entry
  durability are not proven.
- **Integration:** this is the persistent history primitive, not session
  integration, interactive navigation, or a retention policy.

## Next task

M04.06 — dirty-buffer close/quit decisions: one shared safety state machine for
all close origins, requiring successful save, explicit discard, or cancellation
without discarding unsaved content.
