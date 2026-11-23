# M09.06 — Selection stdin/output replacement

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Snapshot and bounded output

`src/core/process/selection.odin` captures a selection's byte range, direction,
text, buffer identity/generation, source revision, request ID, and source window.
The job owns independent stdin and selection-pipe storage, so later caller changes
do not alter the snapshot. Selection input is limited to 16 MiB. Stdout uses a
fixed 1 MiB default buffer with a validated 16 MiB hard limit; exceeding the
limit fails the pipe without applying partial output.

Pump consumption remains nonblocking and bounded by the caller's frame budget.
Stdout is collected for replacement while stderr is drained without creating a
job-output buffer. A pipe becomes ready only after successful process exit and
complete pump drainage.

## Transactional replacement and conflicts

Application validates buffer ID, generation, request ID, and source revision
before calling `txn.doc_apply`. A successful replacement is one `.Command_Output`
transaction and one undo step. The resulting selection covers the replacement
and preserves the original direction. Other views of the buffer transform their
selections through the ordinary view path.

Stale identity/revision and unavailable source-view conflicts leave the document
unchanged. A complete conflicted result transfers to the source buffer for
explicit `Apply`; failed, cancelled, and overflowing pipes do not apply partial
output or open a job window. Errors use the ordinary editor error path.

The source window is stored in the selection target and remains the job's Stop
attachment. Ordinary external command invocation remains M09.10; the only product
launch added here is the explicit `HAMMER_TEST_PIPE_JOB` integration hook.

## Tests

The process suite now has 22 tests. New cases use the purpose-built helper to
verify exact Unicode stdin/stdout, stderr routing, reversed selections, one-step
undo, stale revision and identity rejection, output replay, invalid inputs, and
cancellation after the stdout budget is exceeded. Allocator tracking is clean.

`tests/integration/builtins/x11_harness.py` also starts a separate real-editor
scenario. It filters the whole file selection asynchronously, waits for the
replacement, saves through `Putall`, and checks the exact UTF-8 file bytes.

## Validation

```text
odin run make.odin -file -- process-test
    -> 22/22 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including 22 process tests
odin run make.odin -file -- builtin-test
    -> existing built-ins, flood output, and Stop passed
    -> real selection pipe replacement and save passed
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product and process-test source checks passed
git diff --check
    -> passed
```

The pinned Odin toolchain does not provide an `odin fmt` command; no formatter
was run.

## Not validated and next task

Windows selection-pipe behavior was not executed natively. No general `>`, `<`,
or `|` command routing is claimed yet. Explicit application of stale output and
more selective range-conflict handling remain open.

Next: M09.07 should implement the stale-target conflict workflow, including an
explicit user action for applying preserved output without overwriting newer
selection edits implicitly.
