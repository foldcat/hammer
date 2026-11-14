# M04.01 — Versioned checksummed journal

Session doc for `src/core/journal` (2026-11-14): explicit binary recovery
framing and valid-prefix replay (SPECS.md §11.3–§11.4). Transaction payloads
remain opaque; transaction serialization/application is M04.05.

## Format and identity

All integers are fixed-width little-endian fields; no native struct memory is
serialized. Format and record versions are independently pinned at 1.

```text
File:   fixed header (160 bytes) + path bytes + CRC32
Record: payload length u32 + record version u32 + sequence u64
        + timestamp i64 + payload + CRC32
```

The file header contains the path, platform `File_ID`, size/mtime stamp,
SHA-256 base-content hash, full encoding/newline metadata, session ID,
process-instance ID, and creation timestamp. Header CRC32 covers the fixed
fields and path. Record CRC32 covers the record header and payload. CRC32 is
integrity detection, not adversarial authentication.

`validate_identity` requires exact path, base hash, file identity, and
size/mtime agreement before records may be applied to disk-backed text.
Identity-less filesystems need an explicit opt-in and still require the other
fields to match. Untitled buffers may use an empty path and no file identity.

## Write and replay contracts

- `create` uses exclusive creation and user read/write permissions; it never
  overwrites an existing journal. Failed creation closes and removes only the
  newly created file. The default policy syncs the header and every record;
  `.None` makes written-versus-synced explicit and requires `writer_sync` when
  durability is needed. Close alone is not a durability acknowledgment.
- `writer_append` requires the next contiguous sequence and bounds payload,
  record count, and total file bytes. Short writes are completed. Any append
  or sync I/O failure poisons the writer so no later record can be hidden
  behind a partial one. Earlier records are left intact for replay.
- `replay` validates the complete header, then returns records through the last
  complete verified record. `valid_bytes` is the exact valid-prefix length.
  `Replay_Status` distinguishes clean EOF, torn tail, checksum mismatch,
  sequence/version mismatch, and payload/record/file budget stops. Bad final
  records and budget stops do not discard or mutate the earlier journal.
- Replay owns its path, record array, and every payload. `replay_destroy`
  releases them with the creating allocator. Writer and hooks are synchronous,
  single-owner values; no worker, editor state, or transaction root is touched.

Default limits are 4096 path bytes, 1 MiB per payload, 65,536 records, and
64 MiB per journal. Each limit is configurable; zero selects the default and
negative values are rejected.

## Tests and validation

`tests/unit/journal` uses a unique system-temp sandbox per test and is included
in the standard `make.odin test` target. Fourteen tests cover metadata/binary
round trips, empty-path untitled journals, every torn-tail offset, checksum and
later-record exclusion, record version/sequence/length validation, exclusive
creation and header failures, all write/replay limits, strict identity status,
a SHA-256 known vector, 64 seeded random records, short writes, sync failure,
and poisoned-writer behavior.

```text
odin check src/core/journal -no-entry-point -vet          -> clean
odin check src/core/journal -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/journal -vet -collection:hammer=src  -> 14/14,
    leak-free (memory tracking enabled)
same targeted command, 20-run loop                         -> 14/14 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 14/14
odin run make.odin -file -- test                           -> 18 packages,
    203 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
```

## Traps found

1. Named result cleanup must not destroy storage already copied to an error
   return. Replay uses a separate local owner, destroys it on errors, and
   returns an empty result; successful prefix results transfer ownership.
2. Constant and procedure-parameter arrays are not addressable for slicing in
   the pinned Odin. Encoding copies the magic and base hash to locals first.
3. A package-level `append` procedure shadows the built-in dynamic-array append
   throughout the package, so the public writer operation is `writer_append`.
4. Empty strings must not be freed as owned allocations. Untitled replay cleanup
   checks for an empty header path; zero-length payload slices remain valid.
5. Fault injection counts actual short writes, not logical record sections; the
   test arms failure only after a valid first record has been completely written.

## Platform status and limits

- **Linux:** implemented and tested with isolated real files, deterministic
  corruption/fault injection, repeated and single-threaded leak checks, full
  core suite, both builds, and application smoke.
- **Windows:** the package cross-checks for `windows_amd64`; no Windows runtime
  or real-filesystem behavior was exercised in this session.
- **Durability:** explicit sync support is implemented, but process-kill and
  power-loss durability are not proven by these tests. Directory synchronization,
  checkpointing, rotation, and discovery are separate tasks.
- **Integration:** no product buffer/session consumer is wired yet. This slice
  supplies the journal primitive only; it does not itself replay transactions
  into a rope or make close/quit decisions.

## Next task

M04.02 — periodic checkpointing and rotation: build a bounded checkpoint and
journal-generation policy on this verified-prefix primitive, preserve current
recovery data across rotation, and test checkpoint-plus-tail reconstruction and
interrupted rotation without implementing discovery or stale-lock detection.
