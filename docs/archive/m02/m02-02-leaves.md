## M02.02 done (2026-11-12 session)

Leaves, metrics, and range iteration (`docs/notes/m02-02-leaves.md`) — the
SPECS.md §7.1 Piece/Leaf/local-metrics layer on top of M02.01:

- New backend-free `src/core/rope`: `Piece` (store_id + byte_start +
  byte_length over chunk ids), pool-allocated `Leaf` (≤ 8 inline
  pieces + local `Metrics`; `core:container/pool` with an intrusive
  `link` field — stable pointers, libc-free), `Sequence` (leaf list +
  totals + target leaf size, append-only builder closing leaves by
  piece count or byte bound), `Metrics`/`Boundary` with exact
  boundary-aware `combine` (multi-byte scalars and CRLF split across
  piece boundaries count once, including a tail-carry case for
  all-continuation runs), and flatten-free range reads: `read`
  (caller-buffered partial fills), `read_all`, and a `Span_Iter`
  yielding borrowed chunk slices. `.Invalid_Input` for bad ranges and
  pieces (via a new non-asserting `chunk.lookup`), `.Resource_Limit`
  for allocation failure with the sequence left consistent.
- `tests/unit/rope` added (11 tests): hand-checked metrics cases,
  combine split-invariance at every split point (incl. invalid lead
  sequences), tail-carry/broken-completion merges, append+flatten,
  leaf splitting (piece count and byte bound) with per-leaf metrics
  recomputation, partial reads, span iteration, validation errors,
  arena lifetime, allocation-failure injection, and a 300-step seeded
  differential property checked against BOTH `metrics_of` of the
  flattened reference AND an independent oracle implementation (the
  differential test caught two real combine/decode bugs that inspection
  and single-implementation checks missed).
- Validated: 11/11 rope tests leak-free (×5, no flake); full suite via
  `odin run make.odin -file -- test` (76 tests, all packages clean);
  debug/release builds; Xvfb release smoke (exit 0, no PANIC/ERROR);
  `-no-crt` Windows cross-build of a throwaway consumer + Wine 11 run
  (multibyte+CRLF split-chunk round-trip, metrics, exit 0). No product
  consumer yet (M02.05 wires the buffer registry).

