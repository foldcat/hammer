## M02.04 done (2026-11-13 session)

Coordinate conversion (`docs/notes/m02-04-coords.md`) — the SPECS.md §7.3
byte/scalar/line/column layer over the persistent tree:

- New `coord.odin` in `src/core/rope`: distinct `Scalar_Index`/
  `Line_Index`/`Column_Index` types; a shared `Coord_Cursor`
  forward-walk state (scalar decode with pending tail + break counter
  with provisional-CR carry) derived from folded metrics so subtree
  skips and piece decodes agree exactly with `metrics_of`/`combine`;
  O(depth) descents by byte offset, scalar index (first-own rule), and
  break index (resolved-break rule); at most one piece decoded per
  conversion — no flattening. `tree_byte_to_scalar`/
  `tree_scalar_to_byte`/`tree_byte_to_line`/`tree_line_start(_end)`/
  `tree_byte_to_line_col`/`tree_line_col_to_byte` (+ scalar variants),
  `tree_scalar_count`/`tree_line_count`, all bounds-validated. Grapheme
  positions explicitly deferred to M05.02 (segmentation context).
- `tests/unit/rope/coord_test.odin` added (5 tests; 24 in the
  package): hand-computed cases, empty-tree edges, bounds errors,
  round-trip properties, and a 400-step randomized differential
  comparing every conversion at every position against an independent
  linear-scan model. The differential caught a real tree bug
  (document offsets mixed with chunk offsets → non-monotonic
  scalar_to_byte) and two reference-model bugs (CR-resolution order,
  stale line_count).
- Validated: 24/24 rope tests leak-free (×10, no flake); full suite
  via `odin run make.odin -file -- test` (89 tests, all packages
  clean); debug/release builds; Xvfb release smoke (exit 0, no
  PANIC/ERROR); `-no-crt` Windows cross-build of a throwaway consumer
  + Wine 11 run (coordinate round-trips, known positions exact, exit
  0). No product consumer yet (M02.05 wires the buffer registry).

