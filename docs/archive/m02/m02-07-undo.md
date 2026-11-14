## M02.07 done (2026-11-13 session)

Branching in-memory undo (`docs/m02-07-undo.md`) — the SPECS.md §8.4
undo tree over the M02.05 log:

- The log **is** the tree: `Log_Entry` gained parent/child ids,
  timestamp (`core:time`, CRT-free), and before/after selection state;
  `Doc` gained `current` (node id, 0 = initial state) and a global
  `next_revision` counter (branching breaks `after = base + 1`, but
  revisions stay unique — the §4.3 stale-rejection contract is
  untouched). `doc_apply` links the new node under the current one
  (all-or-nothing: selection validation, op copy, log reserve, and
  parent-children reserve all roll the root back; the children append
  is the final step). `doc_check` validates the tree: dense ids,
  strictly increasing revisions, parent/child symmetry, base/before-
  root/before-selection vs the parent, current state vs tree root,
  counters.
- New `undo.odin`: `Selection` (anchor/active/affinity/visual column,
  bounds-validated at apply), `doc_undo`/`doc_redo` (pointer-only
  state jumps, no allocation), `doc_undoable`/`doc_redoable`;
  `.NotFound` added to errs for the boundary cases. Grouping via the
  M02.05 `grouping_key`: a maximal run of consecutive nodes sharing a
  nonzero key is one undo unit in both directions. Undo + new edit
  creates a sibling; the abandoned branch and its snapshots survive;
  redo follows the most recently applied child. `anchor_transform`
  revised to replay the current path; anchors on abandoned branches
  are `.Conflict` (never silently transformed).
- `tests/unit/txn/undo_test.odin` added (7 tests; 18 in the package):
  linear undo/redo with selection restore, branching retention, group
  undo/redo, selection recording/validation, timestamp sandwich,
  anchors across branches, and a 600-step randomized differential
  (apply/undo/redo with random groups and selections + an anchor pool
  vs an independent reference tree, mirroring every step). The
  differential caught two test-side bugs (a zero-padded reference
  clone; an all-colliding empty-op step that is a doc no-op).
- Validated: 18/18 txn tests leak-free (×10, no flake; also
  single-threaded); full suite via `odin run make.odin -file -- test`
  (108 tests, all 12 test-bearing packages clean); debug/release
  builds; Xvfb release smoke (exit 0, no PANIC/ERROR); `-no-crt`
  Windows cross-build of a throwaway consumer + Wine 11 run (group
  undo/redo, branching, stale/abandoned-anchor conflicts, path
  transform, doc_check, exit 0). No product consumer yet (M06 wires
  selections and grouping keys; M03/M04 add file identity and
  persistence).

