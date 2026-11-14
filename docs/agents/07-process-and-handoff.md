# Process, definition of done, and handoff

Referenced from `AGENTS.md`.

## 23. Debugging and failure discipline

When a check fails:

1. Capture the exact failure.
2. Identify whether it is pre-existing or introduced.
3. Reduce to the smallest useful reproducer.
4. Inspect the relevant API/version.
5. Fix the cause.
6. Add a regression test.
7. Rerun relevant validation.

Do not:

- Catch every failure and return success.
- Suppress all compiler diagnostics.
- Remove assertions indiscriminately.
- Increase limits without understanding the cause.
- Retry a hung test indefinitely.
- Delete state that might contain user work.
- Rewrite a subsystem as the first debugging step.

After repeated non-progressing attempts, stop and report the blocker.

## 24. Definition of done

A task is complete only when:

- The requested behavior or invariant exists.
- Ownership and lifetime are clear.
- Error handling is implemented.
- Cancellation is handled where applicable.
- Resource use is bounded.
- Relevant tests exist.
- Relevant validation was actually run.
- Existing behavior is not unintentionally broken.
- Documentation matches implementation.
- Platform claims match validation.
- No acceptance-path stub remains.

If validation cannot run, the task may be implemented but remains
unvalidated or partially validated.

Do not mark a whole milestone complete because one task is done.

## 25. End-of-session review

Before finishing:

1. Inspect the diff.
2. Look for unrelated edits.
3. Look for accidental generated files.
4. Look for secrets or personal paths.
5. Review unsafe boundaries.
6. Review allocations and cleanup.
7. Review queue/cache/output bounds.
8. Confirm owned test processes have exited.
9. Confirm temporary mounts are cleaned up if approved tests used them.
10. Update relevant task records.

Do not remove artifacts useful for diagnosing a failure without noting it.

If an owned process cannot be stopped safely, report its verified identity
and the situation. Do not escalate to killing unrelated processes.

## 26. Required handoff

End with:

### Task

The exact task attempted.

### Changes

The behavior/invariant added and modules changed.

### Validation

Exact commands run and their outcomes.

### Not validated

Platforms, tests, or scenarios not exercised.

### Risks/blockers

Known limitations, pre-existing failures, or unresolved ownership questions.

### Next task

One concrete next action and its acceptance criteria.

Never claim:

- Tests passed when they were not run.
- Memory safety was proven by compilation.
- Cross-platform support was proven by one-platform testing.
- A stub is a finished feature.
- No data loss is possible after an OS kill or power failure.

## 27. Final checklist

Before calling a task done:

- [ ] Scope is limited to the task and necessary prerequisites.
- [ ] Existing user work is preserved.
- [ ] Pinned Odin APIs and compiler options were verified.
- [ ] No invented syntax or standard-library calls remain.
- [ ] Owned versus borrowed memory is clear.
- [ ] No temporary/frame/worker memory escapes its lifetime.
- [ ] Nested owned resources are destroyed correctly.
- [ ] Native resources have matching cleanup.
- [ ] Partial initialization is safe.
- [ ] External input is validated without assertion-only handling.
- [ ] Unsafe code is localized and justified.
- [ ] Buffer edits use transactions.
- [ ] Background results are revision-validated.
- [ ] Queues, retries, output, and caches are bounded.
- [ ] Save failures preserve dirty state.
- [ ] Close/quit cannot silently discard unsaved work.
- [ ] Tests use isolated state.
- [ ] No unrelated process or real user data was touched.
- [ ] Relevant checks/tests were actually run.
- [ ] Platform status is stated honestly.
- [ ] Diff and generated artifacts were reviewed.
- [ ] NEXT.md and docs/roadmap/ are updated where applicable.
- [ ] Handoff names one exact next task.
