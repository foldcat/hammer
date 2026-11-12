# What to do?

Complete the M00 section, one task per session, in order. Write your
documentations in `/docs`.

## Current task: M00.09 — Record architecture decisions and compatibility inventory

Write `/docs/m00-09-decisions.md` (or similar) recording: backend
decisions (X11 locked in; native Wayland option documented; Windows
deferred), pinned toolchain/dependency inventory, per-feature platform
status (clipboard/DPI/IME/PTY/FUSE: implemented-and-tested vs
implemented-not-tested vs unsupported vs blocked), and open follow-ups
from the M00.03–M00.08 spikes (shader tooling pins, XGetWindowProperty
crash workaround, weston headless seat trap, TIOCSPTLCK requirement,
FUSE read-buffer invariant, fusermount3 new-style protocol, etc.).

## M00.08 done (2026-11-12 session)

`spike/fuse/` (`fuse-spike` target in `make.odin`) plus
`docs/m00-08-fuse.md` — minimal FUSE deployment proof on Linux, raw
`core:sys/linux` syscalls, no libfuse, no new dependencies:

- Unprivileged path verified end to end: direct mount(2) fails EPERM
  (recorded); the working path is the **fusermount3 (libfuse 3.18.3)
  new-style protocol** — socketpair + `_FUSE_COMMFD` env, helper opens
  /dev/fuse itself and returns the connection fd via SCM_RIGHTS. The
  old-style fd-inheritance protocol is rejected by this fusermount3.
- Kernel protocol surface proven on kernel 6.18.50 (7.45 offered, 7.31
  negotiated): INIT/LOOKUP/GETATTR/OPEN/READ/STATFS/RELEASE/FLUSH/
  OPENDIR/READDIR/RELEASEDIR + SYNCFS(52)→ENOSYS; sha256-byte-exact
  multibyte and 280 KB multi-chunk reads via real ls/cat/stat/find/df.
- Hard trap recorded: /dev/fuse read buffer must be ≥ 4096+max_write
  (else EINVAL one request after INIT); spike uses 256 KiB.
- Lifecycle proven: SIGTERM clean unmount (fusermount3 -u), kill -9 →
  kernel abort → fusermount3 -uz lazy recovery; no leftover mounts.
- Sandbox: mounts only in a task-owned `mktemp -d` under /tmp/opencode/;
  no real mount points touched. WinFsp/Windows deferred (no toolchain).

## Next tasks after M00.09

- M01.01 Implement lifecycle and error-reporting infrastructure.
