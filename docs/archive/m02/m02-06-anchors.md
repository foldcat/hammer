## M02.06 done (2026-11-13 session)

Anchor transformation (`docs/notes/m02-06-anchors.md`) — the SPECS.md §8.3
stable-position primitive over the M02.05 log:

- New `anchor.odin` in `src/core/txn`: `Affinity` (Left sticks to the
  left text — inserts at the anchor push it past; Right sticks to the
  right text — it stays put), `Anchor` (pos + affinity + captured
  revision), `anchor_at` (validated capture at the current revision),
  `anchor_transform` (replays log entries with base ≥ the anchor's
  revision in the applied order; stamps the current revision;
  idempotent at the current revision; `.Invalid_Input` for anchors
  ahead of the document). Delete collapse rules and the replace
  range-end adjacency rule documented and pinned.
- `tests/unit/txn/anchor_test.odin` added (5 tests; 11 in the
  package): affinity/delete/replace hand cases, log replay across
  revisions, and a 400-step randomized differential (a pool of anchors
  at random revisions/positions/affinities vs an independent reference
  transform) that caught two reference-model bugs (unsorted replay
  order; empty-range replace misrule) and a test bug worth recording
  (copying a Doc by value — never do that).
- Validated: 11/11 txn tests leak-free (×10, no flake); full suite
  via `odin run make.odin -file -- test` (100 tests, all 11
  test-bearing packages clean); debug/release builds; Xvfb release
  smoke (exit 0, no PANIC/ERROR); `-no-crt` Windows cross-build of a
  throwaway consumer + Wine 11 run (both affinities through a
  multi-op transaction, stale rejection, exit 0). No product consumer
  yet (M06 selections).

