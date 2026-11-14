# M02.04 — Coordinate conversion

Session doc for `src/core/rope/coord.odin` (2026-11-13): byte ↔
scalar ↔ line/column conversions over the rope tree (SPECS.md §7.3).

## Design

```text
Scalar_Index / Line_Index / Column_Index   distinct int types
Coord_Cursor   forward-walk state: scalar decode + pending tail +
               resolved breaks + provisional-CR carry
descend_byte / descend_scalar / descend_breaks   O(depth) descents
               folding skipped subtrees via combine
```

- **Coordinate systems are distinct** (AGENTS.md §14.3): byte offsets
  remain the rope's native plain int; `Scalar_Index`, `Line_Index`,
  `Column_Index` are distinct types; every conversion goes through
  this module. Grapheme positions are deliberately absent — Unicode
  grapheme rules need segmentation context (SPECS.md §7.2) and are
  owned by M05.02.
- **Semantics.** Scalars follow the M02.02 counting model; a byte
  inside a multi-byte scalar maps to that scalar's index, and
  `scalar_to_byte` returns the scalar's first byte. Lines are split by
  LF and lone CR (CRLF = one break); the break byte belongs to its
  line; `line_count = line_break_count + 1` (an empty tree has one
  empty line); `line_end(N) = line_start(N+1)` (or `total` for the
  last line). Columns count scalars from the line start.
- **One cursor, three machines.** `Coord_Cursor` couples the scalar
  decode (pending continuation count) with the break counter
  (provisional CR resolved by the next byte), derived from folded
  metrics via `cursor_from` so subtree-level skips and piece-level
  decodes agree exactly with `metrics_of`/`combine`.
- **Descents.** Each conversion descends O(depth) — child/piece
  selection by byte offset, by scalar index (a scalar starts in a
  subtree iff it is ≥ the fold before it and < the fold including it),
  or by break index (resolved-break rule that also covers a CR
  resolving exactly at a boundary) — and decodes at most one piece
  (≤ chunk size). No flattening (SPECS.md §7.6).
- **Validation.** All inputs bounds-checked (`.Invalid_Input`);
  conversions operate on the current root.

## Validation run (all commands executed this session)

```text
odin check src/core/rope -no-entry-point -vet          -> clean
odin test tests/unit/rope -vet -collection:hammer=src -> 24/24 (19
    M02.01-M02.03 + 5 new coord tests), leak-checked; 10x repeats,
    no flake
odin run make.odin -file -- test                        -> all packages
    (89 tests total), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/ccheck)
    built with the M02.01 cross flags -> runs under Wine 11: multibyte
    + CRLF text split across 2-byte chunks; byte->scalar and
    line/col round trips at every position; 9 scalars, 4 lines, known
    positions exact, exit 0
```

Test coverage (`tests/unit/rope/coord_test.odin`, 5 tests):
hand-computed cases (multi-byte, CRLF, lone CR, interior bytes, line
start/end); empty-tree edges; bounds errors for every conversion;
round-trip properties on a tricky text; and a 400-step randomized
differential (the M02.03 op mix) comparing **every conversion at every
position** against an independent linear-scan model built after every
10th step.

## Traps found (recorded for later tasks)

1. **Document offsets vs chunk offsets.** `descend_*` accumulate
   `base` as the sum of skipped pieces' lengths — a *document* offset;
   adding `piece.byte_start` (a *chunk-relative* offset) corrupted
   `scalar_to_byte`/`line_start` into non-monotonic results. The
   differential caught it immediately (scalar 6 → byte 8, scalar 10 →
   byte 10). Never mix the two offsets; the piece slice already starts
   at the piece's content.
2. **The differential catches oracle bugs too.** The reference model's
   line pass originally assigned `line_of_byte[i]` before resolving the
   pending CR from `i-1` (a `\r\r` mislabeled the second CR) and then
   computed `line_count` from a stale `line` (trailing CR out of
   bounds). When tree and oracle disagree, verify which side is wrong
   before "fixing" the tree — both were real bugs in this session.
3. **`for a, b := range` is not Odin**: the two-variable range form is
   `for a, b in slice`.
4. **The M01.05 trap re-bites**: ranging over an inline slice literal
   (`for x, i in []int{...}`) is a syntax error — bind the literal
   first.
5. **`end` is an Odin keyword** — unusable as a variable name
   (`line_end` results need another name).
6. **Declaration shadowing is a hard error** in this pinned Odin:
   re-using `err :=` in later sibling loops (after an earlier `err :=`
   at proc scope) fails — use distinct names per loop.
7. **Column underflow reveals monotonicity breaks**: a negative column
   (`byte_to_scalar(40) < byte_to_scalar(line_start)`) was the first
   symptom of trap 1 — coordinate mappings must be monotone; the
   all-positions model comparison is the right oracle for that.
8. Carried: `-define:ODIN_TEST_THREADS=1` to separate races from
   logic bugs; reference models must mirror ops exactly (M02.03 trap
   5); no `core:map`; xorshift64 for test randomness.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 24/24 rope tests leak-free (10x, no flake), product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (coordinate round-trips consumer, exit 0); not tested on real Windows hardware |

No product consumer yet (M02.05 wires the buffer registry; the UI
layers consume coordinates from M06 onward).

## Follow-ups (not part of M02.04)

- Grapheme positions and grapheme-boundary clamping — M05.02
  (Unicode segmentation).
- Conversions over snapshot roots (only the current root today) —
  add when a consumer needs them.

## Next task

M02.05 — Transactions and revision tracking.
