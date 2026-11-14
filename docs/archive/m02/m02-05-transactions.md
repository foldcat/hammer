## M02.05 done (2026-11-13 session)

Transactions and revision tracking (`docs/notes/m02-05-transactions.md`) —
the SPECS.md §8.1 transaction layer over the persistent rope:

- New backend-free `src/core/txn`: `Doc` (chunk store + tree +
  transaction-level revision + applied log) where `doc_apply` is the
  only mutation path. `Transaction` (id assigned on apply, source
  enum, base_revision, grouping_key, ops) with `Operation` =
  Insert/Delete/Replace in base-snapshot coordinates: validated
  (bounds, no overlapping ranges, no duplicate insert positions) and
  applied in deterministic descending order (delete/replace before an
  insert at the same position) so every original offset stays valid.
  Stale base revisions are `.Conflict` with no mutation (SPECS.md
  §4.3); failed applies roll back the root (and the revision/id when
  the log copy fails) — all-or-nothing. The log records every applied
  transaction with before/after roots and an owned op copy (the M02.06
  anchor / M02.07 undo substrate); `doc_check` validates tree
  invariants plus the log chain.
- `tests/unit/txn` added (6 tests): basic applies with per-entry
  snapshot-root verification, stale rejection, multi-op ordering
  (four input orders → identical content), validation rejections,
  atomic rollback via a fixed-arena log-copy failure, and a 400-step
  randomized differential with periodic stale probes.
- Validated: 6/6 txn tests leak-free (×10, no flake); full suite via
  `odin run make.odin -file -- test` (95 tests, all 11 test-bearing
  packages clean); debug/release builds; Xvfb release smoke (exit 0,
  no PANIC/ERROR); `-no-crt` Windows cross-build of a throwaway
  consumer + Wine 11 run (multi-op transaction, stale `.Conflict`,
  doc_check clean, exit 0). No product consumer yet.

