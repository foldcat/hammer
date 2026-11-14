# 21. Suggested `NEXT.md` format

```markdown
# Current work

Active milestone: M02 — Rope and transactions
Current task: M02.03 — Persistent root updates and balancing

## Goal

Implement insertion and deletion without mutating existing roots.

## Prerequisites

- [x] Immutable backing chunks
- [x] Leaf range iteration
- [x] Metric aggregation
- [ ] Persistent balancing

## Allowed scope

- src/text/
- tests/property/
- bench/text/

## Acceptance

- Existing snapshots remain byte-identical after edits.
- Randomized insert/delete tests match the reference model.
- Tree invariants hold after every operation.
- No whole-buffer copy for a small edit.
- Allocation ownership is documented.

## Validation commands

Record actual project commands here.

## Known blockers

None.

## Next after completion

M02.04 — Coordinate conversion and line lookup.
```

## 21.1 Session handoff format

```markdown
## Session result

Task:
M02.03

Implemented:

- Persistent insert/delete path.
- Node split/merge/rebalance.
- Root snapshot retention.

Validated:

- Command: ...
- Result: ...
- Command: ...
- Result: ...

Not validated:

- Windows benchmark run.

Remaining risk:

- ...

Next task:
M02.04 — Coordinate conversion and line lookup.
```
