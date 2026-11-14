## M03.02 done (2026-11-13 session)

Background chunked loading (`docs/m03-02-fileload.md`) — the
read/capture adapter feeding `src/core/fileid` from real files and
loading content chunked into the M02 chunk store on a worker, with
the `File_ID`/`File_Stamp` captured at load time (SPECS.md §6.4,
§7.5, §11.1 step 2, §4.2–§4.4):

- New `src/core/fileload`: `Capture` (id + stamp, the §11.1 step 2
  checkpoint) via `capture_file` (handle-based fstat — Unix
  st_dev/st_ino through statx, Windows volume serial / 64-bit file
  index through `GetFileInformationByHandle`; `.None` on the
  m03-01-fileid.md conventions; negative-size `.Invalid_Input`; the
  mtime split floors negative times); `load_file` (open → capture →
  read in `chunk_size` chunks → `chunk.intern` → re-fstat and require
  `stamp_equal`, else `.Conflict` with the partial load discarded —
  all-or-nothing; regular files only; a `cancel` flag aborts between
  chunks); and `Loader` (one worker thread, fixed-capacity 4/4
  bounded queues, a thread-safe growing arena owning every request
  copy/result/store, sticky `loader_cancel`/`loader_resume`,
  `loader_close` drains, `loader_destroy` joins and frees without
  deadlocking against result backpressure). Results echo the §4.3
  request_id plus the worker thread id; the remaining §4.3 fields
  attach with the buffer registry.
- `tests/unit/fileload` added (19 tests): capture vs an independently
  built `os.stat` stamp, `.None` conventions, mtime-split boundaries,
  multi-chunk multibyte/CRLF round-trips, repeated-chunk interning,
  empty files, error paths, upfront cancel, two concurrent-writer
  property tests (atomic temp+rename flips — success must equal one
  complete state; in-place truncate+write — success must be a
  complete state or the legitimate momentary empty state, else
  `.Conflict`), and loader tests (backgroundness, id echo + FIFO,
  cancel/resume, close-drains, mid-load cancel on a 64 MiB fixture,
  destroy discarding unconsumed results, destroy of a never-started
  loader). The first property draft
  caught that a truncate-then-write writer momentarily empties the
  file — a 0-byte success is a *valid* snapshot; the test now pins
  that explicitly.
- Validated: 19/19 fileload tests leak-free (×20 flake loop, no
  flake; also single-threaded); full suite via `odin run make.odin
  -file -- test` (142 tests, all 14 test-bearing packages clean);
  debug/release builds; Xvfb release smoke (exit 0, no PANIC/ERROR);
  `-no-crt` Windows cross-build of a throwaway consumer + Wine 11 run
  (capture, `.None` conventions, validation error path, chunked load
  round-trip with stamp match, the worker loader — exit 0). No
  product consumer yet (M06/M07 wire buffer open; M03.06 reuses
  `capture_file` for conflict detection).

