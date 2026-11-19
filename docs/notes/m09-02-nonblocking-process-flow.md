# M09.02 — Nonblocking stdin/stdout/stderr flow

**Status:** done on Linux. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine process execution was not validated.

## Pipe I/O and ownership

`read_pipe` and `write_pipe` in `src/core/process/process.odin` perform one
nonblocking operation and return `.Data`, `.Would_Block`, `.End`, or `.Closed`
plus a partial byte count or structured error. Parent pipe endpoints are
fixed-location owned values. After `.Would_Block`, the caller keeps the buffer
valid and unchanged until that pipe completes or is closed.

Linux enables `O_NONBLOCK` only on the three parent endpoints after the exec
handshake, so child standard streams remain blocking. Windows uses unique
byte-mode named pipes with overlapped parent endpoints and synchronous child
endpoints. Each `Pipe` lazily owns its overlapped event. Closing a pipe cancels
and retires a pending operation before releasing the event and native handle.

## Bounded pump

`src/core/process/pump.odin` adds a UI-callable, fixed-location `Pump`:

- One poll issues at most one stdin write and one read per output stream; it
  never waits for pipe readiness or child exit.
- Stdin is borrowed and written incrementally with explicit completion/EOF.
- Stdout/stderr become ordered `Data`, `End`, and `Error` records. Sequence
  numbers record observation order only; separate pipes do not establish a
  perfect global order of child writes.
- The record ring and two in-flight read buffers are allocated at
  initialization. The default record queue is 64 records of 16 KiB (1 MiB),
  with separate per-stream read buffers. Record capacity is capped at 4096 and
  queued data at 16 MiB. A full queue stops output reads, applying natural pipe
  backpressure instead of growing memory.
- Record data and errors remain pump-owned until `pump_release`. Polling does
  not invalidate queued records. Input errors return directly from `pump_poll`;
  output errors belong to their stream records.
- `pump_cancel` closes all three directions and preserves queued records for
  draining. It does not signal or reap the child. Process termination and job
  state belong to M09.03. `pump_destroy` releases remaining records and fixed
  storage but does not destroy the borrowed process handle.

## Tests

The process suite now has eight tests. The new flood test pumps 256 KiB of stdin
while the purpose-built child emits 4096 numbered lines on each of stdout and
stderr. A two-record, 64-byte queue is deliberately filled and held full before
draining. The test checks queue/byte bounds, monotonic observation sequences,
exact per-stream output, both EOF records, full input delivery, exit status,
and allocator cleanup. The cancellation test first queues `ready\n`, then
verifies idempotent cancellation closes every endpoint and preserves that record
until release. Existing direct pipe tests now use the shared nonblocking API.

## Validation

```text
odin run make.odin -file -- process-test
    -> 8/8 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including process tests
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check src/core/process -no-entry-point -vet -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product, implementation, tests, and helper source checks passed
```

The Windows helper also cross-linked successfully with the repo-local MinGW SDK
and Rust LLD shim. Wine 11.0 is installed, but the Windows test-runner link could
not proceed because the test CRT requires `libcmt.lib`, which is not available
in the repo's MinGW SDK mapping. No Windows runtime result is claimed.

## Not validated and next task

Native Windows/Wine execution, Windows handle-inheritance behavior under the
new named-pipe transport, and Windows overlapped cancellation remain runtime
unvalidated. Output spill files, UI batching, job lifecycle, process-group
termination, and the Stop command are separate M09 tasks.

Next: M09.03 should add nonblocking job state/lifecycle polling and bounded Stop
cancellation/escalation that reaps owned children without waiting on the UI.
