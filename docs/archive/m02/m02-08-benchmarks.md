## M02.08 done (2026-11-13 session) — M02 complete

Randomized differentials and bounded benchmarks
(`docs/m02-08-benchmarks.md`) — the SPECS.md §7.7 property matrix and
the §7.6 complexity targets as executable checks, closing M02:

- `tests/unit/rope/bench_test.odin` (4 tests): a deterministic
  no-whole-buffer-copy guard (a 32-byte insert / 48-byte delete on a
  2 MiB tree must allocate ≤ 256 KiB through a counting allocator,
  create < 64 tree nodes, intern only the inserted bytes, and keep
  height < 64 — three independent deltas, so no path hides a
  flattening regression); the §7.7 huge-single-line case (4 MiB,
  one line, sampled coordinate round-trips); and wall-clock insert
  scaling (16 KiB vs 4 MiB: 5.5 vs 5.9 µs/op, ratio 1.08) and range
  reads (100 vs 145 ns/op, ratio 1.45) — logarithmic, not
  buffer-proportional.
- `tests/unit/txn/bench_test.odin` (2 tests): the same deterministic
  guard at the `doc_apply` level on a 2 MiB document, plus
  transaction-apply scaling (32 KiB vs 4 MiB: 8.3 vs 12.5 µs/op,
  ratio 1.52).
- `tests/unit/txn/stack_test.odin` (1 test): the whole-stack 600-step
  randomized differential — one xorshift64 stream drives multi-op
  transactions (groups + selections), undo/redo with branching, and
  four independent references: content, tree structure, a re-derived
  metric oracle, and a linear-scan coordinate model, plus `doc_check`
  every 10 steps.
- `make.odin` gained a `bench` target (single test thread,
  `-define:ODIN_TEST_BENCHMARKS=true` prints the measured times; the
  timing guards always run with generous 50x ratios + a 100 µs
  absolute escape, so the ordinary `test` target stays flake-free).
- Validated: 28/28 rope + 21/21 txn tests leak-free (×11, no flake;
  also single-threaded); full suite via `odin run make.odin -file --
  test` (115 tests, all 12 test-bearing packages clean); debug/release
  builds; Xvfb release smoke (exit 0, no PANIC/ERROR); Windows
  cross-build + Wine 11 smoke re-run for the make.odin edit (exit 0).
  No product code changed.

