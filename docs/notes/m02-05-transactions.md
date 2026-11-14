# M02.05 — Transactions and revision tracking

Session doc for `src/core/txn` (2026-11-13): the transaction layer
over the persistent rope (SPECS.md §8.1): every edit goes through a
transaction, revisions track document generations, and stale
operations are rejected.

## Design

```text
Doc           chunk store + tree + transaction revision + applied log
Transaction   id, source, base_revision, grouping_key, ops
Operation     Insert | Delete | Replace   (base-snapshot coordinates)
Log_Entry     id, source, base/after revisions, before/after roots,
              owned deep copy of the ops (applied order)
```

- **One mutation path.** `doc_apply` is the only way text changes
  (AGENTS.md §14.1); the tree is public for reads only.
- **Revision.** `doc.revision` (u64, 0 = empty) bumps exactly once per
  applied transaction; it is the buffer revision for stale rejection
  and background-result validation (SPECS.md §4.3). The tree's own
  revision counter remains an internal mutation counter — not the
  buffer revision.
- **Stale rejection.** `base_revision != current` → `.Conflict`, no
  mutation, no log entry — the "never apply stale results silently"
  rule.
- **Original-snapshot coordinates** (SPECS.md §8.2): operations are
  expressed against the base state. `doc_apply` validates them (bounds
  against the base snapshot; no overlapping ranges; no duplicate
  insert positions; an insert may sit exactly at a range boundary) and
  applies them in a deterministic order — descending start position,
  delete/replace before an insert at the same position — so every
  original offset stays valid during application. The log stores the
  applied order. Empty transactions and empty-data inserts are no-ops.
- **Atomicity.** Validation failures reject everything up front;
  mid-apply failures (allocation) roll back by restoring the
  pre-transaction root (persistence makes rollback a pointer reset);
  a log-copy failure rolls back the revision and id too. Orphaned
  nodes and interned chunks are retained (immutable, safe).
- **The log** records every applied transaction with before/after
  roots (nil for empty states) and an owned copy of the operations —
  the substrate for M02.06 anchor transformation and M02.07 undo;
  retention/pruning is M02.07/M04's concern (unbounded for now,
  documented).

## Validation run (all commands executed this session)

```text
odin check src/core/txn -no-entry-point -vet           -> clean
odin test tests/unit/txn -vet -collection:hammer=src  -> 6/6,
    leak-checked, 10x repeats — no flake
odin run make.odin -file -- test                        -> all 11
    test-bearing packages (95 tests total), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/dcheck)
    built with the M02.01 cross flags -> runs under Wine 11:
    multi-byte seed, multi-op transaction, stale-base .Conflict,
    doc_check clean, revision 2/log 2, exit 0
```

Test coverage (`tests/unit/txn`, 6 tests): single-op applies with id/
revision/log-chain checks and per-entry snapshot-root verification;
stale-base rejection (`.Conflict`, no mutation); multi-op ordering
(same ops, four input orders, identical content vs the reference);
validation rejections (bounds, overlapping ranges, duplicate insert
positions, insert-inside-range; no-ops); atomic rollback on a log-copy
allocation failure (fixed-arena injection); and a 400-step randomized
differential (1..4 random non-overlapping ops per transaction vs a
reference model applying the same deterministic order, plus periodic
stale probes).

## Traps found (recorded for later tasks)

1. **The pinned Odin's union syntax is bare member names**:
   `union { Insert, Delete, Replace }` — the `name: Type` form is a
   syntax error, and `switch` cases use the *type* names
   (`case Insert:`). Multi-case bindings (`case Delete, Replace:`)
   don't yield a usable field binding — use helpers instead.
2. **`make` panics on allocation failure**: the log's operation copy
   must use error-returning allocation (`mem.alloc_bytes` +
   reserve/resize) with partial-copy cleanup, or the rollback test
   crashes instead of exercising the rollback path.
3. **Nil roots are legitimate log states**: `before_root` is nil for
   the first transaction and after any delete-everything transaction.
   `doc_check` must not reject them (the snapshot-roots test verifies
   root contents separately).
4. **The reference model must apply the deterministic order**: the
   hand-written "want" initially applied the ops in a convenient order
   and used out-of-bounds `inject_at_elems` positions — compute the
   expected content in the engine's actual order (end-insert first).
5. **Arena sizing for failure injection**: the apply scratch (sorted
   list, chunk/piece lists) shares the caller allocator — a too-small
   arena fails inside tree ops (a confusing bounds crash), not at the
   intended log-copy point. Size the arena for the scratch, oversize
   the data.
6. Carried: original-snapshot descending application keeps every
   offset valid; `end` is a keyword; bind slice literals before
   ranging; declaration shadowing is a hard error; no `core:map`.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 6/6 txn tests leak-free (10x, no flake), product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (transactions + stale rejection, exit 0); not tested on real Windows hardware |

No product consumer yet (the buffer registry arrives with M02.06/M03
consumers; UI wires in from M06).

## Follow-ups (not part of M02.05)

- Selection fields (`before_selection`/`after_selection`,
  `metadata_changes`) attach when anchors (M02.06) and codec metadata
  (M03) exist.
- Log retention/pruning budgets — M02.07/M04.
- The rollback path's mid-apply allocation failure is exercised only
  via the log-copy path (the tree pool cannot be injected); full
  allocator-failure injection needs a fault-injectable tree allocator
  (M02.08).

## Next task

M02.06 — Anchor transformation.
