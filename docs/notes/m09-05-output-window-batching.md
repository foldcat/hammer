# M09.05 — Output-window batching and backpressure

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Bounded output buffer

`src/core/process/output.odin` borrows a transaction document and consumes pump
records in observation order. Each call consumes at most the caller's byte
budget and applies at most one `.Command_Output` transaction. Partial records
remain in the pump with their buffered-byte accounting intact; `End` records are
released and stream errors become ordered output text.

The default batch is 64 KiB and scrollback is 1 MiB, with validated hard limits
of 1 MiB and 16 MiB respectively. Appending beyond scrollback deletes the oldest
bytes in the same transaction as the new insert and records the dropped count.
This slice deliberately uses bounded oldest-byte truncation rather than disk
spill, avoiding synchronous filesystem work on the UI thread. The pump's fixed
record ring remains the upstream backpressure boundary.

Rope trimming alone would not bound memory because undo entries retain roots
and operation data. `txn.doc_collapse_history` therefore clears the undo log
after each successful output update, makes the current root the empty undo-tree
baseline, and preserves the monotonic document revision. Job-output undo
history is intentionally disposable; ordinary file and error-buffer history is
unchanged. Pending data is retained for retry if transaction application fails.

## Editor integration

Each new command receives a `+Job <id>` output window without changing focus.
Rerunning a plain shell command with the same command text and working directory
reuses that window: any previous run is cancelled and detached, and the retained
output is cleared in one transaction before the new job streams into it. Other
plain commands and working directories keep separate output. Selection-routing
jobs write successful stdout directly to the source buffer without a job window.
`Job_Output` is distinct from `+Errors`: it cannot use file save/reload paths,
its tag offers `Del Stop`, and its window becomes the job's Stop attachment. The
log remains visible after the process slot is released. Failed starts and stream
errors appear in the corresponding job window; window-creation failure is
reported and cancels the job rather than silently dropping output.

The frame loop consumes at most 256 KiB across jobs and visits slots round-robin
to avoid starving later jobs. Terminal jobs release only after the pump and
pending error text drain. Automatic output updates mark a previously clean
buffer clean, while user edits remain dirty and protected by the ordinary close
guard. Selection anchors transform through inserts and trimming; only a view
already following the tail jumps to the new end. Viewport line indices are
clamped after trimming. ANSI/UTF-8 stream decoding belongs to M10, not this task.

## Tests

The process suite now has 18 tests. New coverage includes exact ordered flood
content, partial-record consumption, 128-byte batches, a 256-byte scrollback,
dropped-byte accounting, suffix preservation, and zero retained undo entries
with monotonic revisions. A direct append test also checks trimming and rejected
oversized writes.

`tests/integration/builtins/x11_harness.py` now starts both the ignore and flood
helpers. It requires the flood job to release through the real output-window
path, checks updated view IDs/counts, and retains the existing built-in and Stop
scenarios. The plain-command case also runs the same command twice and verifies
that a new job ID reuses the original window and buffer while clearing its old
content. The output unit tests cover decoder-state reset and transactional
clearing. The explicit `HAMMER_TEST_FLOOD_JOB` hook is test-only; ordinary
external command routing remains M09.10.

## Validation

```text
odin run make.odin -file -- process-test
    -> 18/18 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including output tests
odin run make.odin -file -- builtin-test
    -> existing built-ins passed
    -> flood output drained through the real output window
    -> Stop terminated and reaped the running job
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
    -> product and process-test source checks passed
git diff --check
    -> passed
```

## Not validated and next task

Windows output-window behavior was not executed natively. Disk spill and crash
recovery of spill files are not implemented in this slice; bounded truncation
is the active retention policy. No perfect cross-pipe write ordering or ANSI
rendering is claimed.

Next: M09.06 should capture selection text and target identity for asynchronous
stdin and stdout replacement, using transactions and revision preconditions.
