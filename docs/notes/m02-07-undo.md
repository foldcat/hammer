# M02.07 — Branching in-memory undo

Session doc for `src/core/txn` (2026-11-13): the branching undo tree
(SPECS.md §8.4) built over the M02.05 applied-transaction log — undo
followed by a new edit creates a branch instead of destroying the
abandoned one; grouping via the M02.05 `grouping_key`.

## Design

The M02.05 log **is** the undo tree. Each `Log_Entry` became a node:

```text
Log_Entry
  id, source, base, after, grouping_key   (M02.05)
  parent:   Transaction_ID                (0 = initial state)
  children: [dynamic]Transaction_ID       (apply order; last = most recent)
  timestamp: time.Time                    (wall clock, core:time — CRT-free)
  before_root / after_root                (M02.05, retained snapshots)
  before_selection / after_selection      (new, see Selection)
  ops                                     (M02.05 owned copy, applied order)

Doc
  store, tree, revision                   (M02.05)
  current:       Transaction_ID           (current node; 0 = initial state)
  next_id:       u64                      (M02.05)
  next_revision: u64                      (new global revision counter)
```

- **Revisions are a global counter.** Branching breaks `after = base +
  1`: `after` comes from `doc.next_revision`, so revision values are
  unique across the whole tree (dense only on linear histories). The
  stale-rejection contract (SPECS.md §4.3) is untouched:
  `base_revision` must equal `doc.revision`, which is always the
  current node's `after`. The doc's tree `revision` field is still the
  internal mutation counter, unrelated.
- **`doc_apply`** (same signature) validates ops and
  `after_selection` against the post-edit document, applies, then
  appends the node: `parent = doc.current`, `before_selection` = the
  parent's `after_selection`, timestamp, roots, and the owned op copy;
  finally it appends the child id to the parent's children and moves
  `doc.current`/`doc.revision`. Counters bump only on full success;
  every fallible step (tree op, selection validation, op copy, log
  reserve, parent-children reserve) rolls the root back — the apply
  stays all-or-nothing, and the parent-children append is the last
  step so nothing fails after it.
- **Undo/redo** (`undo.odin`) move `doc.current` and reassign the
  tree root pointer — no tree mutation, no allocation:
  - `doc_undo`: jump to the parent of the current node's group leader;
    restore `before_selection` of the group leader (= the target's
    `after_selection`); the root becomes the leader's `before_root`.
  - `doc_redo`: jump to the deepest node of the grouping run starting
    at the **most recently applied child** of the current state (the
    deterministic "active branch" rule); restore its `after_selection`.
  - `doc_undoable`/`doc_redoable` are the boundary predicates; undo at
    the initial state / redo at a leaf is `.NotFound` (new errs kind).
- **Grouping** (SPECS.md §8.5): a maximal run of consecutive nodes
  sharing a nonzero `grouping_key` along the parent chain is one undo
  unit. Undo from any node in the run jumps past the whole run; redo
  restores the whole run. Nodes with key 0 are their own group. No
  time-based grouping exists — keys come from the producer (M06).
- **Selection state** (SPECS.md §8.3): `Selection{anchor, active,
  affinity, visual_column}` — byte offsets preserving direction, the
  M02.06 `Affinity`, and the preferred visual column (f64, 0 = none).
  Recorded per node; bounds-validated at apply (`.Invalid_Input`
  rolls back); M06 owns real selection behavior.
- **Anchor transform** (`anchor.odin`, revised): replays the **current
  path** — the entries below the node whose `after` equals the
  anchor's revision, in apply order — instead of the whole log array
  (identical behavior on linear histories). An anchor whose revision
  is not on the current path (an abandoned branch) is `.Conflict`:
  never silently transform a stale anchor. Revision 0 (the initial
  state) is always on the path.
- **`doc_check`** now validates the tree structure: dense ids in apply
  order, strictly increasing `after`, parent/child symmetry (both
  directions, children in apply order), `base`/`before_root`/
  `before_selection` matching the parent, the current state matching
  `doc.revision` and `doc.tree.root`, and the counters
  (`next_id = len(log)+1`, `next_revision = last.after+1`).
- **Retention:** the log is never pruned in M02; abandoned nodes and
  their roots stay valid forever (M04/M14 own pruning). Undo/redo do
  not touch the tree's node pool — roots are shared snapshots.
- **No labels yet:** SPECS.md §8.4's "optional descriptive label" is
  deferred to M14 (interactive tree); the node struct is ready for it.
- **Dirty state:** §8.6's saved-checkpoint revision hooks into
  `doc.revision`/`doc.current` at M03.06/M04.06; not implemented here.

Backend-free: `core:time` only (raw clock_gettime / Win32 — CRT-free,
verified by the `-no-crt` Windows build); no Sokol (SPECS.md §4.2).

## Validation run (all commands executed this session)

```text
odin check src/core/txn -no-entry-point -vet -collection:hammer=src
    -> clean
odin test tests/unit/txn -vet -collection:hammer=src
    -> 18/18 (11 M02.05/06 + 7 new undo tests), leak-checked; 10x
    repeats — no flake; also -define:ODIN_TEST_THREADS=1
odin run make.odin -file -- test
    -> all 12 test-bearing packages (108 tests total), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10) -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/xcheck)
    built with -target:windows_amd64 -linker:lld -no-crt
    -no-thread-local + the M00.03 import-lib list (ODIN_LLD_PATH =
    build/lld-link-shim) -> runs under Wine 11: group undo/redo,
    branching (abandoned t3 retained), stale .Conflict, abandoned-
    branch anchor .Conflict, path anchor transform, full undo/redo
    chains, doc_check, exit 0
```

Test coverage (`tests/unit/txn/undo_test.odin`, 7 tests):

- `test_undo_redo_linear`: content/revision/selection at every undo and
  redo of a 3-transaction chain, boundary `.NotFound`, the
  `undoable`/`redoable` predicates, and final state.
- `test_undo_branching`: undo + new edit creates a sibling; the
  abandoned node, its child link, and its retained snapshot survive;
  redo follows the most recent child.
- `test_undo_grouping`: a key-7 run undoes/redoes as one unit; key-0
  boundaries; a single-node group.
- `test_selection_recording`: per-node before/after selection,
  out-of-range and negative after-selections rejected with no
  mutation.
- `test_node_timestamp`: the timestamp is sandwiched between
  `time.now()` probes around the apply.
- `test_anchor_across_branches`: abandoned-branch `.Conflict`,
  path-anchor replay through the branch's own edits only, current-
  revision no-op, future `.Invalid_Input`, redo past the abandoned
  node.
- `test_undo_randomized_differential`: 600 steps of random apply/
  undo/redo (random 1..3-op transactions, random grouping keys that
  build runs, random selections) against an independent reference
  tree; after every step: current/counters/node-fields/child-lists
  (the reference computes children by scanning, not lists), content
  every 10 steps, and a pool of in-place anchors transformed through
  both implementations with error-kind agreement. `doc_check` runs
  every 10 steps and at the end.

The differential caught one real test-side bug (the reference clone
padded `base_content` with zeros — `make(len)` pre-fills, so cloning
must start at len 0) and one reference-gap (an all-colliding random
step produces an empty op list, which is a doc no-op — the reference
must mirror it instead of committing a node). Both recorded in §Traps.

## Traps found (recorded for later tasks)

1. **`make([dynamic]T, len)` pre-fills**: cloning a dynamic array as
   `make([dynamic]u8, len(src))` + `append(..src)` doubles the length
   with leading zeros. Start the clone at len 0 (`make(..., 0, len)`).
   The padded reference content silently diverged from the doc (it
   even passed the non-content mirror checks) until an apply failed on
   bounds.
2. **A no-op is a no-op is a no-op**: a transaction with an empty op
   list applies nothing — no node, no counters. Reference models must
   mirror no-op handling exactly (an all-colliding random op
   generation can produce the empty list).
3. **Redeclaration via `:=` is a hard error in one scope**: `a, b :=
   ...` declares both names; neither may already exist in that scope
   (no "assign existing + declare new" form). Use fresh names per
   declaration (the M02.04 trap, generalized: it also bites tuple
   results like `(Selection, Error)`).
4. **Odin string concat is constants-only**: `"FAIL: " + format` does
   not compile; use `fmt.tprintf` with a static format.
5. **Differential strength**: node-count parity (counters), child-list
   symmetry, and restored-selection equality catch branching bugs that
   pure content checks miss — and content checks every 10 steps catch
   what the structural mirrors cannot. Keep both frequencies.
6. Carried: never copy a Doc by value; reference models replay the
   applied order; bare-name unions; no `core:map`; xorshift64;
   block-scoped defers.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 18/18 txn tests leak-free (10x + single-threaded, no flake), product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`, `core:time` via Win32) + run under Wine 11 (consumer: branching, grouping, anchors, exit 0); not tested on real Windows hardware |

No product consumer yet (M06 wires selections/undo keys into the
editor; M03/M04 add file identity and persistence).

## Follow-ups (not part of M02.07)

- Log pruning/retention policy — M04 (persistent history) and M14
  (interactive tree UI: branch jumps, labels, checkpoints).
- `doc_jump(node_id)` for arbitrary branch switching — M14.
- Dirty-state tracking over `doc.current` (SPECS.md §8.6) — M03.06/
  M04.06.
- `visual_column` policy and selection direction conventions — M06.

## Next task

M02.08 — Randomized differential tests and benchmarks for the
completed rope/txn stack (SPECS.md §7.7 property matrix, same
differential discipline as M02.02–M02.07; benchmarks bounded, not
flattening).
