# M09.03 — Job lifecycle and Stop command

**Status:** done on Linux. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Nonblocking process lifecycle

`try_wait` adds nonblocking exit polling with the same reaping and handle
ownership as `wait`. `request_stop` never waits for exit:

- Linux signals the child's process group with `SIGTERM`, escalating to
  `SIGKILL`. An already-destroyed group is treated as an exit race, not an error.
- Windows creates each process suspended, assigns it to an owned Job Object,
  and resumes it before releasing the initial thread. Forced cancellation uses
  `TerminateJobObject`, covering descendants. A graceful `CTRL_BREAK_EVENT` is
  best-effort because nonconsole children cannot receive it; the forced deadline
  remains the guaranteed path. Reaping terminates any remaining job descendants
  and releases both native handles.

## Job service

`src/core/process/job.odin` provides 32 fixed job slots with stable IDs and the
specified `Queued`, `Starting`, `Running`, `CancelRequested`, `Exited`, and
`FailedToStart` states. Each slot owns its process handle, pump, copied input,
command/working-directory metadata, exit status, and first terminal error.

`job_service_poll` polls pipes and `try_wait` without blocking. Exit does not
truncate output: `Exited` jobs continue pump-only polling until both streams end
and queued records are consumed. Only a reaped, drained terminal job is
releasable. Failed starts remain inspectable and releasable, and retained slots
count toward the bounded registry.

`Stop` closes pipe flow, requests graceful termination, and escalates after a
500 ms default grace period (configurable in service options). Repeating `Stop`
retries forced termination immediately. Window invocation cancels matching
attachments; global invocation cancels all running jobs. The editor owns the
service, polls it once per frame, exposes `Stop` in the global tag, and performs
shutdown cleanup through the same service.

`job_service_destroy` is the shutdown-only last resort: it force-stops and reaps
active trees and discards undelivered records. A failed reap leaves that job and
the service alive for a retry instead of asserting or losing the native handle.
Frame polling never calls the blocking primitive.

## Tests

The process suite now has 13 tests. New coverage includes:

- Normal exit with exact stdout/stderr, owned input, status, and idempotent release.
- Selective attachment cancellation while another job remains running.
- A helper that ignores `SIGTERM`, fake-clock deadline escalation, and `SIGKILL`.
- Failed-start inspection, bounded retained capacity, and slot reuse.
- Forced destruction of an active uncooperative child with allocator cleanup.

`tests/integration/builtins/x11_harness.py` also starts the purpose-built ignore
helper through the explicit `HAMMER_TEST_IGNORE_JOB` test hook, executes the
visible global `Stop` command, and waits for the child PID to disappear from
`/proc`. This validates the actual editor command without adding external
command routing, which remains M09.10.

## Validation

```text
odin run make.odin -file -- process-test
    -> 13/13 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including process/job tests
odin run make.odin -file -- builtin-test
    -> all existing built-in scenarios passed
    -> Stop terminated and reaped the real test job under X11
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product, job implementation, tests, and helper source checks passed
git diff --check
    -> passed
```

## Not validated and next task

Windows Job Object assignment, descendant termination, console fallback, and
reaping were not executed natively. The Windows test-runner CRT mapping remains
blocked as recorded in M09.02. No cross-platform runtime claim is made.

Next: M09.04 should capture an explicit, bounded working-directory and
environment snapshot for job invocation, without reading mutable editor state
later from a worker or concatenating shell text.
