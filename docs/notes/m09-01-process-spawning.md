# M09.01 — Process spawning and handle ownership

**Status:** done on Linux. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; native Windows/Wine execution was not performed.

## Process boundary and ownership

`src/core/process/process.odin` provides direct executable-plus-argument-array
spawning. It has no shell parsing or executable-format shell fallback. The
caller supplies an optional working directory and either an exact KEY=VALUE
environment or nil to inherit the parent environment. Input is bounded to 1024
arguments, 4096 environment entries, and 1 MiB total; embedded NUL and malformed
environment entries are rejected before resource creation.

A successful spawn returns one unique, noncopyable `Handle` containing the
process identity/native handle and three owned parent-side pipe endpoints.
`pipe_handle` borrows an endpoint for platform I/O. `close_pipe` is idempotent.
`wait` blocks the calling thread, reaps the child, returns its exit/signal
status, and releases the native process handle. `destroy` requires that `wait`
has reaped the child, closes remaining pipes, and is idempotent. Asynchronous
polling and UI-safe lifecycle handling belong to M09.02/M09.03, not this
low-level blocking wait primitive.

Each spawn uses a growing virtual arena for temporary argument, environment,
path, and platform conversion storage. The arena is freed and destroyed on every
return. Process errors use the existing structured `errs.Error` ownership path.

## Linux

`process_linux.odin` creates three separate close-on-exec pipes plus a
close-on-exec exec-error pipe. Pipe descriptors are normalized above stderr so
`dup2` cannot clobber another source descriptor. After `fork`, the child uses
only raw syscalls: it creates its own process group with `setpgid`, arms
`PR_SET_PDEATHSIG(SIGHUP)` with a parent-identity race check, attaches the three
standard streams, closes every other descriptor with `close_range`, changes to
the explicit working directory, and calls `execve` directly.

Executable names without a slash are searched in the effective environment's
PATH. Empty PATH elements mean the working directory. Missing entries and
permission failures are searched; no ENOEXEC shell fallback occurs. The parent
reads a two-byte errno handshake that closes on successful exec. Failed setup or
exec is reaped before spawn returns, and partial pipe sets are closed.

The descriptor-closing implementation requires Linux `close_range` (Linux 5.9+).
An older kernel returns an explicit unsupported error rather than silently
inheriting unknown descriptors.

## Windows

`process_windows.odin` uses `CreateProcessW` with Microsoft-compatible argument
quoting, explicit UTF-16 environment/working-directory conversion, a new process
group, and no new console window. `STARTUPINFOEXW` and
`PROC_THREAD_ATTRIBUTE_HANDLE_LIST` restrict inheritance to the three child pipe
ends. Parent ends are non-inheritable, child ends are closed immediately after
spawn, the initial thread handle is closed, and the process handle is retained
until `wait`.

The attribute-list allocation is pointer-aligned and its native destructor runs
on every path. Partial initialization and CreateProcess failures close all owned
pipe handles. Windows runtime behavior, native argument round-trips, and handle
inheritance remain unvalidated until a native Windows/Wine run.

## Tests

`tests/unit/process/helper` is a purpose-built no-shell child. Six tests cover:

- Distinct arguments containing spaces, quotes, backslashes, and Unicode.
- Exact environment, explicit cwd, separate stdout/stderr, and exit status 7.
- Stdin input/EOF, output routing, successful status, and idempotent cleanup.
- PATH lookup using only the explicit child environment.
- Empty/NUL/malformed/over-budget input and missing-executable errors.
- Linux process-group setup and inheritance of only stdin/stdout/stderr while a
  deliberately inheritable marker descriptor remains closed.
- Thirty-two failed exec attempts without growing the parent's descriptor set.

`make.odin` adds `process-test`, builds the helper, and runs the tests through
`process_harness.py`, which owns a 30-second external timeout and test-process
cleanup. The same harness runs as part of the ordinary core `test` target.

## Validation

```text
odin run make.odin -file -- process-test
    -> 6/6 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including process tests
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both product source checks passed
odin check src/core/process -no-entry-point -vet -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> Windows process implementation and tests source-check passed
```

The first development run exposed the pinned Odin `prctl` wrapper's requirement
for four variadic argument slots. The corrected call and all subsequent process
runs passed. The superseded faulting test process tree was explicitly stopped
and verified gone.

## Not validated and next task

No native Windows/Wine process execution was available. Nonblocking reads and
writes, flood backpressure, Stop/cancellation escalation, job lifecycle,
contextual command invocation, output windows, and selection pipes remain later
M09 tasks. Middle-click already dispatches highlighted/expanded internal
commands; external command fallback remains M09.10 rather than spawning an
unrouted synchronous child now.

Next: M09.02 should make stdin/stdout/stderr flow nonblocking with bounded,
cancellable pumping and ordered stream records, without blocking the UI or
flattening unbounded child output into memory.
