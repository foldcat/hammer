# 19. What the agent should implement every time

This is the operational part that prevents the project from becoming an impressive pile of unfinished features.

## 19.1 One active milestone

`NEXT.md` identifies:

- Active milestone.
- Current task.
- Prerequisites.
- Allowed scope.
- Acceptance criteria.
- Known blockers.
- Exact next action.

The agent works on the earliest unblocked task in the active milestone.

It does not jump to a visually attractive later feature.

## 19.2 One vertical slice per session

A session should implement something like:

> “Add native Windows clipboard read with Unicode conversion, bounded retries, and adapter tests.”

Not:

> “Implement the entire clipboard subsystem and all editor input.”

And not:

> “Create empty clipboard interfaces and mark clipboard done.”

Each task should end with observable behavior or a tested invariant.

## 19.3 Required session sequence

Every agent session:

1. Read `AGENTS.md`.
2. Read `NEXT.md`.
3. Read the active milestone in `docs/roadmap/`.
4. Inspect existing code and tests.
5. Confirm prerequisites.
6. Write a short implementation plan.
7. Implement the smallest complete slice.
8. Add or update tests.
9. Run relevant tests.
10. Run build/static checks.
11. Update documentation if a contract changed.
12. Update roadmap status.
13. Write the exact next task.
14. Summarize changes, validation, and remaining risks.

## 19.4 Definition of done for an individual task

A task is complete only when:

- Behavior is implemented.
- Ownership/lifetime rules are clear.
- Errors are handled.
- Cancellation is handled where applicable.
- Relevant tests exist.
- Tests were actually run, or inability to run is explicitly recorded.
- No hidden stub remains in the task’s acceptance path.
- Documentation matches behavior.
- Supported-platform status is accurate.

If Windows could not be tested, write:

```text
Implemented; Linux tested; Windows validation pending.
```

Do not write:

```text
Cross-platform complete.
```

## 19.5 Scope guard

The agent may fix a prerequisite bug if necessary.

It must not:

- Rewrite unrelated modules.
- Change dependency versions casually.
- Replace the architecture to simplify one task.
- Introduce a new UI framework.
- Bypass transactions.
- Silence failing tests.
- Remove compatibility requirements to make progress appear faster.

Architecture changes require an ADR.
