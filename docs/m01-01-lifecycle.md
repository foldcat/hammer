# M01.01 — Lifecycle and error-reporting infrastructure

**Status:** done (Linux/X11 validated headless; Windows cross-build
validated under Wine 11). Real-desktop and real-Windows runtime
validation remain the recorded follow-ups (D-02 / M01 ledger).

This is the first M01 task: the application shell's lifecycle state
machine, logging, structured recoverable errors, and the platform
service interface seam — SPECS.md §18 M01 deliverables ("application
lifecycle", "logging", "platform service interfaces") with the M01
acceptance rule "no dependency-specific code leaks into the core".

## What was built

New packages (all backend-free; none imports Sokol):

| Package                  | Responsibility                                                        |
| ------------------------ | --------------------------------------------------------------------- |
| `src/core/errs`          | Structured recoverable errors: `Kind` (Invalid_Input/Unsupported/IO/Conflict/Cancelled/Resource_Limit/Internal), `Error` value, `new`/`newf`/`ok`/`destroy`/`describe`. |
| `src/core/logging`       | Editor logging subsystem: console + optional file sink, mutex-serialized emission, bounded log file (truncate > 1 MiB at open), panic reporter. |
| `src/core/lifecycle`     | Application phase state machine: Uninitialized → Initializing → Running → Quitting → Shutdown → Exited, with `Quit_Reason` and owned fatal-error plumbing. |
| `src/platform`           | Platform service interface table (`Window_Service`: framebuffer size + dpi scale) — the seam M01.03, M06.04, M06.07 extend. |

Tests live in `tests/unit/{errs,logging,lifecycle,platform}` (17 tests),
outside `src/` — see the trap below for why. `make.odin` gained a `test`
target; `ols.json` gained the `hammer` collection (`./src/`).

`src/main.odin` is now the application layer: it implements the platform
window service with Sokol, drives the lifecycle from the Sokol
callbacks, installs the logger and panic reporter into every context
(main + callbacks), and keeps the M00.03 window/GL demo behavior plus
its autoquit test hook.

## Design contracts

### errs — owned messages

`Error` stores its message string plus the allocator it was made with,
so `destroy` is self-contained and allocator mismatches are impossible
(AGENTS.md §10.4). `.None` is the no-error sentinel (empty message,
destroy is a safe no-op). Assigning an `Error` transfers ownership by
copy; never destroy both copies.

### logging — single instance, bounded, panic-safe

- `init` once at startup (console sink unconditional; file sink optional
  and never fatal — a failed file open returns the error while console
  logging stays live), `shutdown` once after all workers stopped.
- Emission is serialized under one mutex; every line is written with a
  single unbuffered write, so concurrent workers (M01.05) cannot
  interleave lines.
- Log files are bounded by truncation at open (≥ `MAX_FILE_SIZE`).
  Rotation is deliberately absent; it lands together with recovery
  journal rotation (M04).
- `panic_proc` (installed as `context.assertion_failure_proc`) writes the
  panic into the log file and hands off to
  `runtime.default_assertion_failure_proc` (stderr + abort). It never
  takes the emit mutex: the panic may have fired while that mutex was
  held, and a locked panic path hangs instead of reporting.

### lifecycle — one mutation owner, idempotent quit

`request_quit` is idempotent (keyboard, window close, autoquit hook, and
later IPC race through one door; the first reason wins). Fatal reasons
(`Init_Failed`, `Fatal_Error`) require an error, which transfers
ownership into the `App`. `cancel_quit` exists for the SPECS.md §11.6
"Cancel" decision and is restricted to user-requested quits — fatal
errors can never be silently discarded. Illegal transitions assert
(programmer invariants, AGENTS.md §11.2); the M04.06 dirty-buffer review
plugs into `Quitting` without changing this shape.

### platform — proc-pointer seam

`Services` is a plain struct of proc pointers with a `user: rawptr`
(no vtables, no allocation). The core depends only on these; the Sokol
implementation lives in `main`. M01 acceptance: the four core packages
build without the Sokol collection, and the `test` target never passes
it.

## Traps found (and how they are handled)

1. **`_test.odin` files are compiled into every build on the pinned
   Odin (dev-2026-11), including normal builds and imports.** Verified
   with a `#assert(false)` marker: importing a package with an
   in-directory test file compiles that file, which dragged
   `core:testing` (→ `core:c/libc`) into the Windows `-no-crt`
   cross-build and broke it. Fix: tests live in `tests/unit/<pkg>` and
   import the source packages through the `hammer` collection. Never
   put `_test.odin` files inside `src/` packages while the product
   builds with `-no-crt`.
2. **The Odin test runner executes tests on several threads in
   parallel.** The logging tests mutate subsystem-global state, so they
   serialize on a package-level mutex. Pure tests (errs, lifecycle,
   platform) need no gate.
3. **`core:testing` has no `errorf`** in the pinned version;
   `testing.expectf(t, false, fmt, ..)` is the failure-reporting form.
4. **Wine panic path:** an unhandled `ud2` (Odin's `trap()`) makes Wine
   launch `WineDbg` interactively, which hangs headless runs. In the
   task-owned `/tmp/opencode/wine-prefix` the AeDebug registry keys were
   set (`Auto=1`, `Debugger` exits) so the crash terminates. The panic
   message and the unhandled-illegal-instruction termination are
   validated; the exact exit-code behavior on real Windows hardware is
   not (no Windows CI runner — D-02).
5. Small API notes for later tasks: `fmt.tprintf` is scratch-allocated;
   `os.temp_directory` requires an explicit allocator; `os.open` uses
   `File_Flags` bit sets, and default-opened files are unbuffered
   (line-atomic writes under the logging mutex).

## Validation run (all commands executed this session)

Unit tests (headless, sandboxed, leak-checked by the runner):

```text
odin run make.odin -file -- test
-> tests/unit/errs      6/6 pass
-> tests/unit/logging   5/5 pass  (incl. 2-thread concurrent emit test)
-> tests/unit/lifecycle 5/5 pass
-> tests/unit/platform  1/1 pass
```

Linux/X11 (Xvfb + llvmpipe, sandboxed `HAMMER_LOG`):

```text
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG=$SANDBOX/hammer.log ./build/hammer
-> exit 0; full lifecycle in the log (starting -> running -> quit requested
   (Autoquit; second User_Request proves idempotence) -> shutdown -> exited);
   no leaked allocations reported at exit (tracking allocator).

xvfb-run -a env HAMMER_TEST_PANIC=1 HAMMER_LOG=$SANDBOX/hammer-panic.log ./build/hammer
-> exit 132 (SIGILL = Odin trap()); stderr shows the default panic output;
   log file contains the [PANIC ] [file:line:proc] line.

release build + 5-frame smoke: exit 0.
HAMMER_LOG="" (console-only): exit 0; no user state directory touched.
```

Windows (cross-build + Wine 11, task-owned WINEPREFIX, Xvfb + llvmpipe):

```text
odin run make.odin -file -- windows            -> hammer.exe builds (debug)
xvfb-run -a env WINEPREFIX=$PREFIX HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine-vanilla-11.0 build/hammer.exe
-> exit 0; identical lifecycle log (os=Windows); console logging works under -no-crt.
HAMMER_TEST_PANIC=1 (AeDebug auto-exit configured in the sandbox prefix):
-> panic message printed, illegal instruction, nonzero exit (no hang).
```

## Honest status

| Platform    | Status                                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------- |
| Linux/X11   | **tested headless** (unit tests, debug/release smokes, panic path, console-only, leak-free exit). Not yet run on a real desktop (recorded M01 follow-up). |
| Windows     | **cross-build + Wine-validated** (window/GL run, full lifecycle, console logging, panic path). Real Windows hardware untested (D-02 blocks release gates until a CI runner exists). |

## Follow-ups (owners)

- M01.03 consumes `dpi_scale` + `framebuffer_size` for logical/physical
  coordinate conversion (rule: divide by `dpi_scale`, per
  `docs/m00-09-decisions.md` §5).
- M01.05 workers install the logger per thread (`logging.install`).
- M04.06 inserts the dirty-buffer review at the `.QUIT_REQUESTED`
  handler (`cancel_quit` is the Cancel path).
- M04: log-file rotation alongside recovery-journal rotation.
- M01 (general, pre-existing): real-desktop window run; CI config
  commit — both still open, neither is M01.01's deliverable.
