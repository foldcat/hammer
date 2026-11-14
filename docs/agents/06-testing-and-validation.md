# Testing and validation

Referenced from `AGENTS.md`.

## 19. Safe test environment

Tests should be:

- Headless by default.
- Deterministic where practical.
- Bounded.
- Repeatable.
- Independent of personal machine state.

Create a unique sandbox per test run.

Route test state into it:

- Configuration.
- Recovery.
- History.
- Project layout.
- Runtime IPC files.
- Output spill files.

Use explicit application test options where possible.

Do not rely only on environment variables if the application can still
fall back to real user directories.

Tests must never auto-load the user's actual session.

Subprocess tests should use a small purpose-built helper executable rather
than dangerous or platform-dependent shell commands.

For filesystem traversal tests, include:

- Symlink cycles.
- Paths escaping through symlinks.
- Unicode paths.
- Long paths.
- Permission failures.

Run fault/crash tests in a child process.

An external harness must own the timeout and cleanup.
An in-process timeout is insufficient if the process hangs or deadlocks.

Never simulate disk failure by filling the user's actual disk.

Use injected failures or an approved constrained test filesystem.

## 20. Validation workflow

Use repository wrappers and CI commands when available.

Otherwise, identify the actual package paths and pinned-toolchain options.

Typical command families:

- `odin check <package>`
- `odin build <package>`
- `odin test <package>`

These are templates, not commands to execute with literal placeholders.

Verify supported flags with the installed compiler help.

Run validation in increasing cost order:

1. Relevant static/check step.
2. Targeted unit tests.
3. Relevant integration tests.
4. Broader regression suite.
5. Approved benchmarks/platform tests.

Use the repository's formatter if one is configured.
Do not run a repository-wide formatter for a small change.

Use supported vet checks.
Do not silence a useful diagnostic globally to fix one instance.

Keep development checks enabled unless a measured, narrowly scoped reason
justifies otherwise.

Use Odin's testing facilities and allocator tracking where applicable.

Allocator tracking does not detect every native/GPU resource leak.
Test those resources separately.

Tests may be parallel by default; configure approved bounded concurrency
using the pinned toolchain's supported mechanisms.

Record randomized test seeds on failure.

Do not repeatedly rerun a flaky test until it passes and report success.
Investigate or report the flakiness.

## 21. Required test categories

Choose the categories relevant to the task.

### Unit

- State transitions.
- Parsing.
- Range validation.
- Error paths.
- Ownership-sensitive helpers.

### Property/differential

- Rope versus a simple reference model.
- Insert/delete/undo round trips.
- Coordinate conversion.
- Anchor transformation.
- Randomized chunk boundaries.
- Journal replay.

### Integration

- Open/edit/save/reopen.
- Shared-buffer views.
- Async replacement conflicts.
- IPC transactions.
- Project restoration.

### Platform

- Native clipboard.
- DPI.
- IME.
- Unicode filenames.
- Process cancellation.
- PTY/ConPTY.
- File replacement.
- FUSE/WinFsp.

### Failure injection

- Allocation failure where supported.
- Partial writes.
- Save failure.
- Stale revisions.
- Worker disconnect.
- Torn journal records.
- Output overflow.
- Cancellation during shutdown.

A bug fix should normally include a regression test that fails without
the fix.

Do not delete or weaken a test merely because it reveals a bug.

## 22. Cross-platform honesty

Keep platform-specific code behind platform adapters.

Use compile-time platform selection where appropriate.

Do not assume:

- POSIX means identical behavior everywhere.
- Windows paths always use one separator.
- All Windows filesystems are case-insensitive.
- All Unix filesystems are case-sensitive.
- Text files use one newline convention.
- Font discovery is portable.
- Clipboard behavior is uniform.
- File replacement semantics are identical.

Cross-compilation is not runtime validation.

Report platform status accurately:

- Implemented and tested.
- Implemented but not tested.
- Unsupported.
- Blocked.

Do not write "cross-platform complete" after testing one platform.
