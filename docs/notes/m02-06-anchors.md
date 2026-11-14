# M02.06 — Anchor transformation

Session doc for `src/core/txn/anchor.odin` (2026-11-13): stable
positions that survive edits (SPECS.md §8.3) — a plain integer offset
is not enough for delayed clipboard results, asynchronous pipes, IPC
clients, layout restoration, or multiple views.

## Design

```text
Affinity :: enum u8 { Left, Right }
Anchor   :: struct { pos: int, affinity: Affinity, revision: u64 }
anchor_at(doc, pos, affinity)      capture at the current revision
anchor_transform(doc, ^Anchor)     replay the log to the current revision
```

- **Affinity** (an insertion exactly at the anchor's position): `.Left`
  sticks to the text on the left — the inserted text lands between that
  text and the anchor, pushing it past the insertion; `.Right` sticks
  to the text on the right — the anchor stays put.
- **Delete**: before the range → untouched; inside → collapses to the
  range start; at/after the range end → shifts left by the removed
  length.
- **Replace** (the engine's delete-then-insert) with one refinement:
  an anchor exactly at the range end stays adjacent to the text that
  followed the range — it lands after the replacement regardless of
  affinity. An empty-range replace is a pure insert (affinity rules).
- **Replay**: `anchor_transform` replays the M02.05 log (the applied,
  deterministic order) for entries with `base >= anchor.revision`,
  then stamps the anchor with the current revision. An anchor ahead of
  the document is `.Invalid_Input`; one at the current revision is a
  no-op (idempotent). The log is never pruned in M02.06, so any past
  revision is replayable (retention is M02.07/M04's concern).
- The transform needs only operation positions and inserted lengths —
  both carried by the log's operation copies.

## Validation run (all commands executed this session)

```text
odin check src/core/txn -no-entry-point -vet           -> clean
odin test tests/unit/txn -vet -collection:hammer=src  -> 11/11 (6
    M02.05 + 5 new anchor tests), leak-checked; 10x repeats — no flake
odin run make.odin -file -- test                        -> all 11
    test-bearing packages (100 tests total), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/xcheck)
    built with the M02.01 cross flags -> runs under Wine 11: anchors
    through a multi-op transaction (both affinities: 2 vs 1), stale
    anchor .Invalid_Input, exit 0
```

Test coverage (`tests/unit/txn/anchor_test.odin`, 5 tests): insert
affinity at/before/after the anchor; delete collapse rules (before/at
lo/inside/hi/after); replace rules incl. the range-end adjacency case
and empty-range-as-insert; log replay from captured revisions across
several transactions (idempotent re-transform, future-revision
rejection); and a 400-step randomized differential maintaining a pool
of anchors captured at random revisions/positions/affinities, checked
against an independent reference transform after every transaction.

## Traps found (recorded for later tasks)

1. **Never copy a `Doc` (or `Tree`/`Store`) by value**: the first
   anchor test returned the doc from a helper, duplicating dynamic
   array headers and the pool — corrupted state and a segfault in an
   unrelated tree op. Fill caller-owned values through pointers, as
   documented on every no-copy type.
2. **The reference model must replay the applied order**: the log
   stores ops sorted (descending); the reference initially replayed
   the caller's original order and diverged at the first transaction
   with equal-position ops. Sort the reference's copy with its own
   sort implementation.
3. **Empty-range replace is a pure insert**: the reference's
   `pos == hi` rule fired for `hi == lo` (no removed text), treating
   an empty replace as a range-end adjacency — the doc's rule
   (affinity applies) is the correct one. Guard `hi <= lo` first.
4. **Local type declarations do not exist in Odin** — structs used by
   a test proc must live at package scope.
5. **`for want, pos in wants` iterates indices**, not positions —
   parallel arrays when positions are not 0..n-1.
6. Carried: bare-name unions with type-name switch cases; `:=` vs `=`
   shadowing discipline; bind slice literals before ranging; reference
   transforms are independent implementations of the same policy.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 11/11 txn tests leak-free (10x, no flake), product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (anchor transforms, exit 0); not tested on real Windows hardware |

No product consumer yet (selections and delayed clipboard use anchors
from M06).

## Follow-ups (not part of M02.06)

- Selection structs (`anchor`/`active_end`/`preferred_visual_column`)
  compose two anchors at the UI layer (M06); M02.06 provides the
  single-anchor primitive.
- Log retention/pruning — M02.07/M04.

## Next task

M02.07 — Branching in-memory undo.
