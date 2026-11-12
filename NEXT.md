# What to do?

Work through the active milestone one task per session, in order. Write
your documentation in `/docs`.

## Current task: M01.01 — Implement lifecycle and error-reporting infrastructure

See SPECS.md §18 M01 for deliverables and acceptance. First task of the
application shell: application lifecycle, logging, error reporting, and
platform service interfaces (M01.01 per SPECS.md task list), on Linux/X11
(Windows remains blocked by the D-02 deferral recorded in
`docs/m00-09-decisions.md` §4).

Consult `docs/m00-09-decisions.md` before starting: it carries the
architecture decisions (D-01…D-05) and the follow-ups owed by M01
(real-desktop window run, CI config commit, sapp-DPI logical/physical
conversion rule for M01.03).

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
