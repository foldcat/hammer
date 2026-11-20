# M10.05 — PTY/ConPTY process mode

**Status:** Linux implemented and tested. Windows ConPTY is an explicit
`.Unsupported` stub (source-checked only; there is still no Windows toolchain
on this machine). Other platforms return `.Unsupported`.

## What was built

`src/core/process/pty.odin` (shared) and `pty_linux.odin` (Linux) add PTY
process mode, productizing the M00.07 spike findings.

- `Pty` owns a spawned child and one bidirectional master endpoint
  (`master: Pipe`); the child's stdin/stdout/stderr are the slave.
- `pty_spawn(desc, options, allocator)` validates the description, allocates a
  PTY pair, applies the requested termios mode, sets the initial window size,
  and forks. The child runs `setsid` + `TIOCSCTTY` (acquires the slave as its
  controlling terminal), `dup2`s the slave onto fds 0/1/2, arms
  `PR_SET_PDEATHSIG`, then execs through the shared PATH search. Exec failure
  is reported through a dedicated error pipe (same handshake as `spawn`).
- `Termios_Mode`: `.Sane` (echo off so the parent's input is not bounced back;
  ONLCR output post-processing on) and `.Raw` (cfmakeraw-equivalent).
- `Pty_Options` carries the termios mode and initial `Winsize`.
- I/O: `pty_read` maps the Linux EIO-on-master (slave closed) to `.End`;
  `pty_write` reuses the pipe writer; `pty_resize` sets `TIOCSWINSZ`.
- Lifecycle: `pty_try_wait`/`pty_wait`/`pty_stop`/`pty_destroy` mirror the pipe
  `Handle`, but signal the child's process group (the child is a session leader
  via `setsid`).

`build_exec` was extracted from the Linux `platform_spawn` so the pipe and PTY
paths share one argv/envp/PATH-search/environment builder. `pty_windows.odin`
and `pty_other.odin` are `.Unsupported` stubs.

## Tests

`tests/unit/process/pty_test.odin` (6 tests; 35 total in the process package).
The helper gained `pty` (reports `isatty` then echoes one line) and `size`
(reports `TIOCGWINSZ`) modes, with `size` split into `size_linux.odin` /
`size_other.odin` so the helper source-checks on Windows.

- Raw-mode round-trip and clean exit (writes `ping\n`, reads `tty=1\necho:ping\n`).
- Sane mode: echo off (input not bounced back) and ONLCR (`\n` arrives as
  `\r\n`).
- Initial window size reaches the child (`cols=120 rows=34`).
- Dynamic `pty_resize` reaches the child (`cols=80 rows=24`).
- Force-stop kills the process group (SIGKILL, `signal == 9`).
- Missing executable returns `.NotFound` with no live master.

## Validation

```text
odin test tests/unit/process -vet -collection:hammer=src -define:ODIN_TEST_THREADS=1
    -> 35/35 tests passed (includes the 6 new PTY tests)
odin check src/core/process -vet -no-entry-point
odin check src/core/process -vet -no-entry-point -target:windows_amd64
odin check tests/unit/process -vet -no-entry-point -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> source-checks clean on Linux and windows_amd64
odin run make.odin -file -- test
    -> full core unit suite passed
```

## Not validated and next task

ConPTY (Windows) is unimplemented — only the `.Unsupported` stub source-checks;
no Windows runtime result is claimed. The PTY is not yet wired into a terminal
view or the output pipeline (that is M10.06). SIGWINCH delivery on resize was
not exercised (only the shared winsize value was verified).

Next: M10.06 — Integrate a tested terminal-emulation layer (start a terminal
with the `win` command).
