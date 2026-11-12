# What to do?

Work through the active milestone one task per session, in order. Write
your documentation in `/docs`.

## Current task: M01.02 — Add generated trusted configuration package

See SPECS.md §18 M01 for deliverables and acceptance. M01.01 is done;
the application shell now has the lifecycle/logging/error/platform seam
it builds on (see the entry below and `docs/m01-01-lifecycle.md`).

Consult `docs/m00-09-decisions.md` before starting: it carries the
architecture decisions (D-01…D-05) and the follow-ups still owed by M01
(real-desktop window run, CI config commit, sapp-DPI logical/physical
conversion rule for M01.03). Note the M01.01 traps recorded there
(§5): `_test.odin` files are compiled into normal builds, and the test
runner parallelizes tests across threads.

## M01.01 done (2026-11-12 session)

Lifecycle and error-reporting infrastructure (`docs/m01-01-lifecycle.md`):

- `src/core/errs` (owned-message structured errors),
  `src/core/logging` (console + bounded file sink, mutex-serialized
  emission, panic reporter), `src/core/lifecycle` (phase state machine,
  idempotent quit, cancel hook for the M04 dirty review),
  `src/platform` (backend-free service interface table; the Sokol
  implementation lives in `src/main.odin`).
- Tests moved out of `src/` into `tests/unit/` (`hammer` collection):
  pinned Odin compiles `_test.odin` files into normal builds, which
  broke the `-no-crt` Windows cross-build (`core:testing` →
  `core:c/libc`). Trap recorded in `docs/m00-09-decisions.md` §5.
- Validated headless: 17/17 unit tests (leak-checked); Linux
  debug/release Xvfb smokes (exit 0, clean tracking-allocator exit);
  Linux panic path (exit 132, `[PANIC ]` line in the log); console-only
  mode; Windows cross-build + Wine 11 smoke (lifecycle + logging under
  `-no-crt`); Wine panic path (AeDebug auto-exit configured in the
  task-owned WINEPREFIX). Real-desktop and real-Windows runs remain the
  recorded M01/D-02 follow-ups.

## M00.03 Windows half done (2026-11-12 session)

The D-02 Windows deferral was partially unblocked (owner installed
Wine 11 + mingw-w64 32/64) and the M00.03 Windows half executed:

- `odin run make.odin -file -- windows [--release]` cross-builds
  `build/hammer.exe` (`windows_amd64`, Sokol GL) on Linux: mingw-built
  Sokol libs, native lld-link (rust-lld shim / `ODIN_LLD_PATH`), mingw
  import libs as `build/windows-sdk/` `-windows-sdk-root`,
  `-no-crt -no-thread-local`.
- Validated headless under Wine 11 + Xvfb/llvmpipe: window create, GL
  clear, clean shutdown, exit 0 — debug and release.
- Traps + follow-ups (last-`/defaultlib`-only lld quirk, explicit
  Win32/UCRT lib inputs, D3D11 variant, real-Windows validation) are
  recorded in `docs/m00-03-window.md` §Windows and
  `docs/m00-09-decisions.md` §4/§5.

M01.01 remains the active task; the remaining Windows spike halves
(M00.04/05/07/08) stay deferred per D-02.

## M00.09 done (2026-11-12 session)

`docs/m00-09-decisions.md` — the consolidated architecture decision log
and compatibility inventory for M00:

- Decision log: D-01 X11 product backend (sokol/X11); D-02 Windows
  deferred (no toolchain) and explicitly blocking Windows release gates;
  D-03 native Wayland a documented option, not a commitment (three
  candidate paths listed for the Tier-1 gate); D-04 IPC + FUSE/WinFsp
  architecture; D-05 spikes use raw `core:sys/linux`, no libfuse.
- Verified toolchain/dependency inventory (Odin dev-2026-11, sokol-odin
  `ae94aa5`, sokol C `93aa187`, system versions) with explicit
  not-yet-pinned gaps (glslc/M05.01, FreeType/HarfBuzz/M05.01,
  Tree-sitter/M12.01, WinFsp/M19.05).
- Honest feature/platform status matrix (tested vs implemented vs
  unsupported vs blocked) covering window/GL, clipboard, DPI, IME, PTY,
  FUSE, input, CI.
- Consolidated follow-up ledger: every M00.03–M00.08 trap (libX11
  XGetWindowProperty, XIM keymap/MappingNotify traps, weston headless
  seat crash, TIOCSPTLCK, FUSE read-buffer invariant, fusermount3
  new-style protocol, etc.) mapped to its owning milestone.
- M00 acceptance review: all criteria met except the Windows build path
  (blocked by D-02, recorded not dropped). M00 marked done with that
  item; M01 is now active.

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
