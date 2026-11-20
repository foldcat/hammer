# M09.08 — Running-job quit decisions

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Separate job and dirty-buffer guards

`src/core/lifecycle/job_quit.odin` adds a fixed-location `Job_Quit_Guard` with
`Idle`, `Await_Decision`, `Waiting`, `Cancelling`, and `Ready` phases. It supports
`Wait`, `Cancel_Jobs`, and `Cancel_Exit`, validates close origins and pending
counts, and never stops a process or closes a buffer itself. All six close origins
share this headless decision path. Detaching is not offered because the job
service has no supported detach operation.

The editor inspects `Close_Guard` and `Job_Quit_Guard` independently for every
user quit. A retained job slot counts as pending until process exit, output
drainage, error flushing, selection-result handling, and slot release complete.
When a waiting or cancelling quit reaches zero pending jobs, the editor re-runs
the ordinary dirty-buffer inspection. Job completion therefore cannot authorize
exit while unsaved text still requires a decision.

## Product behavior

The global tag now offers `Wait` beside `Stop`:

- `Wait` lets jobs and output finish before resuming the quit request.
- During a job quit, `Stop` cancels all jobs, retains the existing forced-stop
  escalation when repeated, and resumes quitting only after cleanup.
- Ordinary editing, scrolling, layout changes, lookup, and non-decision commands
  cancel the pending exit. Cancellation does not undo a cancellation already sent
  to a job.
- Repeated quit requests preserve an existing `Waiting` or `Cancelling` decision.
- Closing the last view or column now uses the same combined quit inspection.

A clean dirty-buffer `Ready` result is reset if a job decision keeps the editor
open, allowing later requests to re-inspect current state. Sokol OS-close events
call `sapp.cancel_quit()` unless the combined guards actually authorized exit, so
neither running jobs nor dirty buffers can be bypassed with the window close
button. Fatal and autoquit shutdown behavior is unchanged.

## Tests

The lifecycle suite now has 24 tests. New coverage includes every close origin,
explicit cancel-exit, bounded wait completion, cancellation completion, repeated
and invalid decisions, negative counts, overlapping requests, and clean reuse.

`tests/integration/builtins/x11_harness.py` sends real `WM_DELETE_WINDOW` client
messages. It verifies that OS close remains blocked, `Wait` can be cancelled by
editing, and `Stop` reaps the uncooperative helper before the editor exits. A
second delayed-pipe scenario verifies that `Wait` drains and applies output but
still blocks on the resulting dirty buffer until it is saved. Existing selection
conflict and `Apply` coverage remains in the same suite.

## Validation

```text
odin test tests/unit/lifecycle -vet -collection:hammer=src
    -> 24/24 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including 24 lifecycle and 26 process tests
odin run make.odin -file -- builtin-test
    -> OS-close blocking, Wait/cancel-exit, Stop/reap/resume-quit passed
    -> output drainage followed by dirty-buffer blocking passed
    -> existing built-ins and selection conflict scenarios passed
odin run make.odin -file -- mouse-test
    -> all mouse and safe per-view close scenarios passed
odin run make.odin -file -- compatibility-test
    -> all integrated compatibility and dirty-quit scenarios passed
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/lifecycle -no-entry-point -vet -collection:hammer=src -target:windows_amd64
    -> product and lifecycle-test source checks passed
git diff --check
    -> passed
```

The pinned Odin toolchain does not provide an `odin fmt` command; no formatter
was run.

## Not validated and next task

Windows job-quit behavior was not executed natively. IPC and filesystem close
origins are covered by the headless guard tests; those product adapters remain
later milestones. No job-detach behavior is claimed.

Next: M09.09 should implement the named filter-command registry, scoping, and
discovery without executing definitions during enumeration or validation.
