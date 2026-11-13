# M03.02 — Background chunked loading

Session doc for `src/core/fileload` (2026-11-13): the read/capture
adapter that stats real files into `core/fileid` values and loads
content chunked into the M02 chunk store on a worker, with the
`File_ID`/`File_Stamp` captured at load time (SPECS.md §6.4, §7.5,
§11.1 step 2, §4.2–§4.4). This is the first real file-I/O core
package and the first consumer of the M01.05 queue.

## Design

```text
Capture           id: File_ID + stamp: File_Stamp   (the §11.1 step 2 checkpoint)
Loaded            capture + chunk.Store + [dynamic]Chunk_ID (owned;
                  concatenating data(ids[i]) reproduces the file bytes)
Loader            one worker thread, two bounded queues, growing arena
Load_Request      id: Request_ID + path copy + Load_Options
Load_Result       id echo + worker_tid + Loaded + errs.Error
```

- **Capture** (`capture_file`, sync): opens read-only, `fstat`s the
  *handle* (no TOCTOU — the identity names the file the handle is
  bound to, not whatever the path resolves to later), and maps the
  stat fields through `fileid.unix_id` (st_dev/st_ino via statx on
  Linux) / `fileid.windows_id` (volume serial / 64-bit file index via
  `GetFileInformationByHandle` on Windows). The mtime split
  (`time.Time` → sec/nsec) floors negative times into a non-negative
  fraction — pre-1970 mtimes are valid on FAT. A negative stat size
  is `.Invalid_Input`, never asserted. `capture_from_stat` is the
  unit-test seam for the `.None` conventions and the time split.
- **Load** (`load_file`, sync): open → capture → read in
  `chunk_size` chunks → `chunk.intern` each → re-fstat the same
  handle → require `fileid.stamp_equal(pre, post)`, else `.Conflict`
  and the partial load is discarded (all-or-nothing: a failed load
  leaves `*loaded` zero). Memory is one chunk buffer plus the interned
  content. A `cancel: ^bool` parameter (checked atomically between
  chunks) aborts with `.Cancelled`.
- **Loader** (async): one worker thread; request/result queues with
  fixed capacities (4/4, caller-owned storage inside the `Loader`);
  the worker runs with a context whose allocators are the loader's
  growing virtual arena (thread-safe via its internal mutex), so
  request copies, results, stores, id lists, and error messages all
  live on one arena reclaimed by a single `free_all` at
  `loader_destroy`. `loader_submit` blocks on backpressure;
  `loader_poll` is non-blocking; `loader_cancel`/`loader_resume` are
  sticky atomics; `loader_close` drains (cancelled requests fast);
  `loader_destroy` closes, drains with a *blocking* pop (no busy
  spin), joins, and frees — it cannot deadlock against result
  backpressure. The result echoes the §4.3 `request_id` plus the
  worker thread id (diagnostics and the backgroundness proof);
  buffer-id/generation/source-revision attach when the buffer
  registry lands.
- **Only regular files** capture/load (`.Unsupported` otherwise): on
  Linux the open is O_NONBLOCK so a FIFO cannot block the caller; on
  Windows `.Non_Blocking` would map to FILE_FLAG_OVERLAPPED and break
  `os.read` (NULL OVERLAPPED — found the hard way under Wine), and no
  blocking hazard exists there because named pipes are unreachable
  through a plain path open and non-regular files are rejected before
  any read.
- **Symlinks are followed** (identity = target's): `Symlink_Policy`
  `.Follow` is this layer's behavior; `.Preserve_Link` semantics are
  M03.05's decision. `.None` (inode/file-index 0) follows the
  m03-01-fileid.md canonical-value rule: never a registry key.

## Validation run (all commands executed this session)

```text
odin check src/core/fileload -no-entry-point -vet        -> clean
odin test tests/unit/fileload -vet -collection:hammer=src
    -> 19/19, leak-free (memory tracking on), ~200 ms
flake loop x20 (same command)                            -> no flake
single-threaded (-define:ODIN_TEST_THREADS=1)            -> 19/19
odin run make.odin -file -- test                         -> 14 packages,
    142 tests (19 new), exit 0, leak-free
odin run make.odin -file -- build                        -> exit 0
odin run make.odin -file -- --release                    -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)           -> exit 0, clean
    lifecycle shutdown, no PANIC/ERROR lines
Windows -no-crt check: throwaway consumer
    (/tmp/opencode/m03-02-win-consumer, not committed) built with
    -target:windows_amd64 -linker:lld -no-crt
    -no-thread-local -windows-sdk-root:build/windows-sdk
    -extra-linker-flags:"/libpath:build/windows-sdk <product lib list
    + ntdll.lib bcrypt.lib>" -> runs under Wine 11: capture vs
    os.stat, .None conventions, validation error path, chunked load
    round-trip (stamp == capture stamp), the worker loader
    (threads + queues under -no-crt), exit 0
```

Test coverage (`tests/unit/fileload`, 19 tests): capture matches an
independently built `os.stat` stamp (path-based stat — a different
syscall path than the handle fstat); capture error paths
(`.NotFound`, directory → `.Unsupported` on Linux); the `.None`
conventions and zero-dev/serial non-invalidation via
`capture_from_stat`; the mtime split (positive, negative flooring,
exact-second boundary); multi-chunk multibyte/CRLF round-trip with
the chunk-size bound; empty file; repeated-chunk interning (8
identical chunks → 1 stored chunk); load error paths
(all-or-nothing, `.NotFound`, `.Unsupported`); upfront-cancel
`.Cancelled`; two concurrent-writer property tests — atomic
temp+rename flips (every load must equal one complete state) and
in-place truncate+write flips (success must be a complete state or
the legitimate momentary empty state with content length == stamp
size, otherwise `.Conflict`; both classes asserted nonempty) —
plus loader tests: backgroundness (`worker_tid` ≠ caller),
request-id echo + FIFO order, sticky cancel/resume, close-drains +
`.Closed`, error results, mid-load cancel (64 MiB fixture), destroy
discarding unconsumed results without deadlock, and destroy of a
never-started loader (the drain used to block on the still-open
result queue — the regression test pins the fix).

The first property-test draft used a non-atomic in-place modifier and
asserted "success ⇒ content a or b"; it immediately failed with 0-byte
successes — *correct* adapter behavior (the truncate-then-write
pattern makes the file momentarily empty, and a load landing in that
window snapshots the empty state with matching stamps). The test was
split into the two phases above to pin both the strong invariant and
the `.Conflict` contract.

## Traps found (recorded for later tasks)

1. **`.Non_Blocking` breaks Windows reads**: `os.open` maps it to
   FILE_FLAG_OVERLAPPED, and `core:os` reads such handles with
   `ReadFile(..., nil)` — invalid for overlapped handles (the load
   failed with `.Unknown` under Wine). Non-blocking opens are a
   Linux-only device here; Windows needs no equivalent (named pipes
   are not reachable through a plain path open, and the type check
   precedes any read).
2. **`time.Time` is a struct** (`_nsec: i64`), not a distinct i64:
   convert with `time.to_unix_nanoseconds`, and the split must floor
   negative times (`sec -= 1` when `nsec < 0` after `%`).
3. **The pinned compiler rejects a `defer` when the enclosing scope
   ends in a diverging call** (`os.exit(1)` at the end of `main` made
   every earlier defer "unreachable"). The throwaway consumer uses
   explicit cleanup instead.
4. **`os.open` on Linux resolves `/proc/self/fd/N`** (for the
   handle's fullpath name) and `os.fstat` allocates the fullpath
   with the caller's allocator — a /proc-less mount namespace would
   make capture fail; the raw-`statx` fallback is the recorded
   follow-up if it ever matters.
5. **`os.read` on Linux maps EINTR to `.Unknown`** — a signal during
   a load aborts it (`.IO`). Retrying EINTR properly needs the raw
   syscall path; documented, deferred.
6. **`os.write_entire_file` truncates before writing**, so a file
   being rewritten passes through a momentary empty state — any
   concurrency invariant that only allows "old complete content or
   new complete content" must use temp+rename in the modifier (and
   real writers doing atomic replace are exactly the §11.1 pattern
   M03.05 implements).
7. Carried and confirmed: `expect_ok` had to be param-polymorphic
   over `errs.Error`/`os.Error` (distinct types); `testing` has no
   `errorf` (use `expectf(t, false, ...)`); string concat is
   constants-only (fmt.tprintf for path building); `append` is
   `#optional_allocator_error` (capture the `(n, err)`); Windows
   cross-linking needs `ODIN_LLD_PATH` set for a direct `odin build`
   (make.odin's `windows` target sets it); never copy a `Store`
   (results are heap pointers; `Loaded` is an out-parameter).

## Platform status

- **Linux:** implemented and tested (capture via statx on the handle,
  O_NONBLOCK open, chunked load, worker loader — all headless tests
  plus the full-suite/build/smoke runs).
- **Windows:** implemented and tested under Wine 11 (`-no-crt`
  cross-build: `GetFileInformationByHandle` capture, chunked load
  round-trip, the worker loader with `core:thread`/`core:sync` — exit
  0). No real NTFS/FAT volume behavior exercised (Wine maps the file
  index onto the Unix inode); real-Windows validation remains the
  recorded follow-up (M03/D-02).
- **Filesystem behaviors:** symlink-following, `.None`-identity
  filesystems (procfs), and case-sensitivity probing remain untested
  against real volumes — case probing and canonical path resolution
  are the deferred M03.02 follow-ups.

## Follow-ups (not part of M03.02)

- Canonical path resolution (realpath / GetFinalPathNameByHandle) and
  volume case-sensitivity probing feeding `Case_Sensitivity` (listed
  as M03.02 work in m03-01-fileid.md; deferred to the capture layer's
  next slice — M03.06 consumes `capture_file` for conflict detection
  and is the natural home).
- M03.06: wire `stamp_status` into disk-change detection; decide the
  identity-less-filesystem policy for `.Unchanged`.
- M03.05: symlink save semantics; the §11.1 temp-write/rename save
  path (the atomic-replace property test here is its dress rehearsal).
- M03.03: codec/BOM/newline policy on top of `Loaded` (the chunks are
  raw bytes today — correct by design, see m02-02-leaves.md trap 5).
- Buffer registry (M06/M07 wiring): attach the remaining §4.3 fields
  to `Load_Result` and decide `loader_submit` backpressure policy for
  the UI thread.

## Next task

M03.03 — UTF-8/BOM/newline policy (SPECS.md §7.4): the codec metadata
and validation layer over `Loaded` content — preserve LF/CRLF, retain
BOM/encoding metadata, define the invalid-UTF-8 policy (never
silently replace and save destructively), with the decode layer
consuming the chunk store the way this session's loader produces it.
