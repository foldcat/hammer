# M02.08 — Randomized differential tests and benchmarks

Session doc for the M02.08 test/benchmark work (2026-11-13): the
SPECS.md §7.7 property matrix as executable randomized differentials
plus the SPECS.md §7.6 complexity targets as bounded benchmarks. This
closes the M02 test matrix. Headless core only (SPECS.md §4.2); no
product code changed.

## Design

### New tests (all backend-free, in the existing test packages)

`tests/unit/rope/bench_test.odin` (4 tests):

- **`test_tree_small_edit_bounded`** — the deterministic
  no-whole-buffer-copy guard (the M02 acceptance "large insert/delete
  operations do not flatten the entire buffer", made falsifiable): a
  32-byte insert and a 48-byte delete on a 2 MiB tree must (a)
  allocate ≤ 256 KiB through a counting allocator wrapping the caller
  allocator, (b) create < 64 new tree nodes (a rebuild would create
  hundreds), (c) intern only the inserted bytes (chunk-store
  total/chunk deltas), and (d) keep the tree height < 64 (a
  flattening list would be linear). Three independent delta measures
  so no single path can hide a regression.
- **`test_tree_huge_single_line`** — the §7.7 huge-individual-lines
  case: a 4 MiB break-free buffer is one line; sampled
  byte/line/column round-trips hold along the whole line.
- **`test_bench_insert_scaling`** — wall clock: the same 8-byte insert
  at the middle of a 16 KiB tree vs a 4 MiB tree (400 ops each).
  Measured: 5.5 µs/op vs 5.9 µs/op — ratio **1.08**, i.e. the insert
  is logarithmic, not proportional to the buffer (a flattening
  implementation would show ~256x).
- **`test_bench_range_read`** — wall clock: a 64-byte range read on
  the small vs the 4 MiB tree (400 ops each). Measured: 100 ns/op vs
  145 ns/op — ratio **1.45**: the visible-range read is proportional
  to the range, not the buffer (SPECS.md §7.6).

`tests/unit/txn/bench_test.odin` (2 tests):

- **`test_doc_small_edit_bounded`** — the same deterministic guard at
  the transaction level: a 32-byte insert and a 48-byte delete on a
  2 MiB `Doc` through `doc_apply` with the counting allocator, with
  node-count, chunk-store, and height deltas plus `doc_check`.
- **`test_bench_doc_apply_scaling`** — wall clock: small transactions
  on a 32 KiB vs a 4 MiB document (200 ops each). Measured: 8.3
  µs/op vs 12.5 µs/op — ratio **1.52**: transaction application is
  logarithmic in document size.

`tests/unit/txn/stack_test.odin` (1 test):

- **`test_stack_randomized_differential`** — the whole-stack
  differential closing the M02 matrix: one xorshift64 stream drives
  600 steps of random multi-op transactions (with grouping keys and
  selections), undo/redo with branching, and four independent
  reference models checked against the live document — content (the
  undo-tree reference snapshots), structure (ids/revisions/child
  lists, mirrored every step), metrics (a second, independently
  written counting oracle), and coordinates (a linear-scan model at
  sampled positions), plus `doc_check` every 10 steps. Reuses the
  M02.05–M02.07 reference helpers; the metric oracle and the
  coordinate model are re-derived here because test packages cannot
  import each other.

### Benchmark runner

`make.odin` gained a **`bench`** target: runs the rope and txn test
packages with `-define:ODIN_TEST_BENCHMARKS=true`
`-define:ODIN_TEST_THREADS=1`. The define toggles printing the
measured per-op times; the timing guards themselves always run (with
generous 50x ratios plus a 100 µs absolute escape for load noise, so
the ordinary multi-threaded `test` target stays flake-free).

## Validation run (all commands executed this session)

```text
odin test tests/unit/rope -vet -collection:hammer=src     -> 28/28 (24 + 4 new), leak-checked
odin test tests/unit/txn  -vet -collection:hammer=src     -> 21/21 (18 + 3 new), leak-checked
odin run make.odin -file -- test                          -> 115 tests, all 12 test-bearing packages clean
rope + txn x10 (default threads) + x1 (-define:ODIN_TEST_THREADS=1) -> no flake, no leak report
odin run make.odin -file -- bench                         -> ratios 1.08 / 1.45 / 1.52 (see above)
odin run make.odin -file -- build && -- build --release   -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)            -> exit 0, no PANIC/ERROR lines
odin run make.odin -file -- windows                       -> cross-build OK
Wine 11 smoke (Xvfb + HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no PANIC/ERROR lines
```

## Traps found (recorded for later tasks)

1. **`delete` on a `[]byte` slice goes through `context.allocator`**,
   not the allocator the slice was created with: the first version of
   the counting allocator wrapped a buffer arena, and `doc_destroy`'s
   `ops_destroy` (which frees log op data with `delete`) produced
   tracker "bad free" reports for every arena-backed copy. Fixed by
   backing the counting allocator with `context.allocator` — the
   counting is then purely observational and the bound is still the
   correct no-whole-buffer-copy check. (The codebase's own
   `ops_destroy_partial` already knew this — it passes the allocator
   explicitly to `mem.free`.)
2. **A `for pkg in []string{...}` literal range is a syntax error**
   (the M01.05 trap): the `bench` target must bind the package list to
   a variable first.
3. **`odin test pkg1 pkg2` only runs the first package** in the
   pinned compiler (no "all packages" mode was observed): the `bench`
   target and the flake loop must run the packages one at a time.
4. **Arena-allocator defer ordering**: an arena that backs data the
   test owns through `doc_destroy` must be destroyed (and
   `free_all`ed) after the doc, or the frees hit a reset arena. The
   buffer-arena path was removed by trap 1, but the ordering rule
   stands for any future arena-backed Doc test.
5. **`mem_virtual.arena_init_buffer` returns an error** and must have
   its result handled (`@(require_results)`); earlier test files
   already do this.
6. Carried: xorshift64 for test randomness; no `core:map`; bare-name
   unions with type-name switch cases; `:=` shadowing discipline; no
   local type declarations; bind slice literals before ranging;
   `-define:ODIN_TEST_THREADS=1` separates races from logic bugs.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 28/28 rope + 21/21 txn tests leak-free (x11, no flake), 115-test full suite clean, bench ratios ~1.1–1.5, product debug/release + Xvfb smoke unaffected |
| Windows  | product unchanged (no src/ edits this session); the make.odin `windows` cross-build and the Wine 11 smoke were re-run to validate the make.odin edit (exit 0). Benchmarks are not run under Wine (tests need `core:testing` → libc) |

No product consumer yet (the buffer registry and the benchmark harness
consumers arrive in M03+).

## Follow-ups (not part of M02.08)

- CI wiring for the `bench` target and trend tracking — M20.03 owns
  the full §17.2 fixture matrix (1 MiB / 100 MiB / 1 GiB fixtures,
  startup/viewport/typing/scroll latency); the M02.08 benchmarks are
  the bounded in-suite guards, not the release benchmark run.
- Wall-clock guards under Windows/Wine — blocked by `core:testing`'s
  libc dependency (the M01.01 trap); a native Windows test runner is
  a standing follow-up.

## Next task

M02 complete. M03.01 — canonical file identity (SPECS.md M03):
device/inode (or file-id) + version-validated identity for
external-change detection, headless core, with unit tests.
