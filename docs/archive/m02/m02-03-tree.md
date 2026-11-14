## M02.03 done (2026-11-12 session)

Balancing and persistent root updates (`docs/m02-03-tree.md`) — the
SPECS.md §7.1 Internal node / RopeRoot layer:

- New `tree.odin` in `src/core/rope`: a persistent copy-on-write
  B-tree — one kind-tagged `Node` type (leaf pieces or internal
  children, both inline) from a single `core:container/pool` (intrusive
  link; nodes never recycled while any root references them), `Tree`
  (root + revision). Inserts splice interned pieces (boundary piece
  split) and cascade leaf repacks and balanced internal splits;
  deletes split boundary pieces (a same-piece split can leave 9
  survivors → leaf splits), drop emptied leaves, merge under-full
  internal children left-sibling-first, and collapse single-child
  roots. Old roots stay byte-identical (`tree_read_root(_all)`);
  revision bumps exactly once per successful mutation. `tree_check`
  validates bounds, uniform leaf depth, piece validity, and metric
  recomputation; span iteration walks snapshot roots.
- `tests/unit/rope/tree_test.odin` added (8 tests; 19 total in the
  package): build/insert/delete vs the reference model, full-leaf
  split cases, snapshot persistence across edit rounds, validation
  errors, and a 500-step seeded differential (content + metrics vs
  `metrics_of` AND the independent oracle + invariants + revision +
  span iteration + snapshot probes after every op). The differential
  caught three real bugs inspection missed: fixed-array slices
  including zeroed entries, a sibling-merge ordering scramble (which
  also caused a segfault), and a missing `combine` leading-run carry.
- Validated: 19/19 rope tests leak-free (×10 runs, no flake; also
  single-threaded); full suite via `odin run make.odin -file -- test`
  (84 tests, all packages clean); debug/release builds; Xvfb release
  smoke (exit 0, no PANIC/ERROR); `-no-crt` Windows cross-build of a
  throwaway consumer + Wine 11 run (snapshot persistence, revision
  accounting, tree_check clean, exit 0). No product consumer yet
  (M02.05 wires the buffer registry).

