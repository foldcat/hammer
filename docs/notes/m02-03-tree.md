# M02.03 — Balancing and persistent root updates

Session doc for `src/core/rope/tree.odin` (2026-11-12): the persistent
copy-on-write rope tree on top of the M02.01 chunk store and the
M02.02 piece/metrics model (SPECS.md §7.1: Internal node / RopeRoot).

## Design

```text
Node (leaf)       pieces[8] + metrics     (the M02.02 Leaf payload, inlined)
Node (internal)   children[8] + cumulative metrics
Tree              root (nil = empty) + revision + node pool
```

- **One node type, one pool.** `Node` carries a `kind` tag and both
  payloads inline (the unused one is wasted space — deliberately traded
  for boring, type-safe access and a single
  `core:container/pool`-allocated node size with an intrusive `link`
  field). Nodes are never `put` back: every node lives until
  `tree_destroy` (pool.destroy wholesale), so old roots keep their
  nodes — retention/pruning policy is M02.07/M02.08's concern.
- **B-tree shape.** Leaves: 1..8 pieces, ≤ `target_leaf_bytes` (an
  oversized single piece gets its own leaf). Internal: ≤ 8 children;
  non-root ≥ 4; root 2..8 or a leaf; all leaves at one depth. Metrics
  folded with `combine` from children/pieces.
- **Persistence.** Mutations rebuild the affected path with new nodes;
  unchanged subtrees are shared by pointer. `tree_read_root(_all)`
  reads a captured snapshot root: old roots stay byte-identical across
  any number of later edits. `revision` (u64) bumps exactly once per
  successful mutation; no-ops and failures do not.
- **Insert.** Content is interned in the chunk store (split at its
  chunk size) and spliced as pieces at the offset; a piece containing
  the offset is split. Over-full leaves repack (piece sequence →
  packed leaves), over-full internal nodes split by balanced chunking
  (ceil(total/8) nodes of total/n or total/n+1 children, all ≥ 4),
  cascading upward; above the old root, `pack_nodes` rebuilds levels
  bottom-up so leaf depth stays uniform.
- **Delete.** Boundary pieces split (survivors recomputed; the
  same-piece split can leave 9 survivors → the leaf splits in half);
  emptied leaves drop out; under-full internal children merge with a
  sibling (left sibling's children first — order matters); a root
  internal with one child collapses into it; all children deleted →
  nil root. An empty range is a no-op (even on an empty tree).
- **Ordering is content.** `tree_check` validates bounds, uniform
  depth, piece validity, and metric recomputation — but metric folds
  are order-independent, so it cannot see scrambled child order. The
  randomized differential (content equality against the reference
  model) is the ordering oracle.
- **Ownership/failure.** Working lists and error messages use the
  caller allocator of each operation; the tree itself stores nothing
  caller-allocated. `.Invalid_Input` for bad offsets/ranges (tree left
  untouched), `.Resource_Limit` for allocation failure. Backend-free,
  builds under `-no-crt`.

## Validation run (all commands executed this session)

```text
odin check src/core/rope -no-entry-point -vet          -> clean
odin test tests/unit/rope -vet -collection:hammer=src -> 19/19 (11
    M02.02 + 8 new tree tests), leak-checked; 10x repeats, no flake;
    also verified single-threaded (-define:ODIN_TEST_THREADS=1) to
    separate races from logic bugs
odin run make.odin -file -- test                        -> all packages
    (84 tests total), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/tcheck)
    built with the M02.01 cross flags -> runs under Wine 11: split-
    chunk inserts, mid-tree insert + delete, snapshot read of the v1
    root byte-identical, revision 8->10, tree_check clean, exit 0
```

Test coverage (`tests/unit/rope/tree_test.odin`, 8 tests): build by
append (revision/no-op accounting, empty tree); insert at start/
mid-piece/boundary/end vs the reference model; delete prefix/middle/
suffix/mid-piece/empty/full; full-leaf mid-piece delete (the 9-survivor
leaf split); full-leaf insert cascade; snapshot persistence across
multiple edit rounds; validation errors (no revision bump, content
untouched); and a 500-step seeded differential (insert/append/delete)
checking content, metrics (vs both `metrics_of` and the independent
oracle), tree invariants, revision accounting, span iteration, and
snapshot probes after every operation.

## Traps found (recorded for later tasks)

1. **Fixed node arrays must be sliced `[:count]`, never `[:]`.** Two
   splice bugs came from `n.pieces[start:]`/`n.children[idx+1:]`
   slicing to the array end and silently including the zeroed entries
   beyond the count ("piece references unknown chunk id 0"). Always
   bound slices by the count fields.
2. **Sibling merge order matters.** When the under-full child is the
   *last* child, the merge must combine the left sibling's children
   first — passing `(seq[i], seq[j])` blindly scrambled document order
   (content reordering with unchanged length and metrics, invisible to
   `tree_check`), and the corrupted child pointers later segfaulted a
   snapshot read. Merge with `merge_siblings(left, right)` and splice
   at `min(i,j)`.
3. **`combine` needed a leading-run carry** — the left-side analogue
   of M02.02's tail carry: a left run consisting entirely of
   continuation bytes merges its leading run into the right run
   (capped at 3). Caught only by the 500-step differential at step
   307; the M02.02 split tests never started a string with
   continuation bytes.
4. **`tree_check` cannot verify ordering**: metric folds are
   order-independent. Content-equality differential tests are the
   ordering oracle — keep them, and add per-leaf piece recomputation.
5. **Reference-model discipline**: the snapshot probe initially
   injected the reference at the end while the tree inserted at a
   random position — a test bug that produced a *deterministic*
   "oracle mismatch" far from any real bug. Mirror every op exactly,
   and when failures look impossible, diff the reference model first.
6. **Separate races from logic bugs**: `-define:ODIN_TEST_THREADS=1`
   turns a flaky multi-threaded failure into a deterministic one —
   the first debugging step for non-reproducing test failures.
7. **Empty deletes on an empty tree are no-ops**: validate the range
   against the nil root's zero length *before* the empty-range early
   return, or `delete([0,0))` on an empty tree errors.
8. **`inject_at_elems`/`remove_range` are builtins** (no import);
   `inject_at_elems` returns `(ok, Allocator_Error)` — check `ok`.
9. **fmt brace mangling returns**: passing a `fmt.tprintf` result
   containing `%v`-substituted struct prints (`Metrics{...}`) as the
   format to `expectf` makes the pinned fmt re-parse the braces
   (`%!(MISSING ARGUMENT)` noise). Don't embed struct prints in
   formats; print fields individually.
10. Carried from M02.01/M02.02: no `core:map`; intrusive-link pool API
    (self-owned arena, invisible to tracking allocators); xorshift64
    for test randomness; `-no-entry-point` for library checks; Windows
    cross flags + `ODIN_LLD_PATH`; pool reuse vs persistent sharing.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 19/19 rope tests leak-free (10x, no flake), failure/error paths, product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (snapshot persistence consumer, exit 0); not tested on real Windows hardware |

No product consumer yet (M02.05 wires the buffer registry); the M02.02
`Sequence` remains the append-only flat builder alongside the tree.

## Follow-ups (not part of M02.03)

- Node retention/pruning (pool growth with edit history) — M02.07
  undo + M02.08 budgets/benchmarks decide the policy; `tree_check` and
  the differential harness carry forward.
- Real-Windows runtime validation remains the standing D-02 follow-up.

## Next task

M02.04 — Coordinate conversion: byte ↔ scalar ↔ line ↔ (logical
column) conversions over the tree using the M02.02/M02.03 metrics.
