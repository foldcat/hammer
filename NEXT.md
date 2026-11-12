# What to do?

Work through the active milestone one task per session, in order. Write
your documentation in `/docs`.

## Current task: M01.04 — Native input normalization

See SPECS.md §18 M01 for deliverables and acceptance. M01.01–M01.03
are done (see below); M01.04 builds on the window service and
`core/coords` (M01.03: mouse events arrive in framebuffer pixels and
must be converted with `coords.to_logical_point` before any layout or
hit-testing — never apply DPI twice).

The M01.02 traps in `docs/m01-02-config.md` §Traps and the M01.03
traps in `docs/m01-03-coords.md` §Traps are required reading for new
code in `src/` (fmt brace escaping, block-scoped defer, relative
import resolution, `%v` float formatting; Xlib async errors, no
`odin fmt` in the pinned compiler, no `math.is_finite`).

## M01.03 done (2026-11-12 session)

Logical/physical coordinate conversion (`docs/m01-03-coords.md`):

- New backend-free `src/core/coords`: distinct `Physical_*`/`Logical_*`
  size/point structs, validated conversions both directions (divide /
  multiply by `dpi_scale`, finite 0 < scale ≤ 32, `.Invalid_Input` on
  garbage — no assertion on external input), points ↔ logical px
  (×96/72, SPECS.md §9.6), and `points_to_physical_px` as the full
  §9.6 chain.
- `src/main.odin` consumes it: `window_metrics` (startup info + RESIZED
  debug, scale-invalid → warn + fallback to 1.0), startup font log
  (12pt = 16 logical px = 32 physical px at 2×). Window service docs
  updated; `tests/unit/coords` added (8 tests).
- Validated: 39/39 unit tests leak-free; debug/release/run smokes;
  scale 1.0 and 2.0 (Xft.dpi 192); real X11 resize events at both
  scales fed by a task-owned throwaway resizer (not committed);
  custom-config font chain; panic path (132); Windows cross-build +
  Wine 11 smoke (exit 0). Real desktop and mixed-DPI dual-monitor
  remain the recorded follow-ups (M05.06/M01).

## Allocator migration done (2026-11-12 session)

Owner-directed refactor (`docs/m01-alloc-arenas.md`): the panic
allocator previously installed as `context.allocator` was replaced with
explicit arenas per AGENTS.md §10.5:

- `src/main.odin` owns two `core:mem/virtual` arenas: `perm` (whole
  program: logging sinks, errors, config-derived strings — one
  `free_all` at the end of main) and `temp` (frame scratch, installed
  as `context.temp_allocator`, reset at the end of every frame).
  `permanent()` returns the panic allocator until `init_arenas`
  succeeds, so an allocation before arena setup is a loud bug.
- Call sites now pass explicit allocators (`logging.init`,
  `config.describe`); core packages were already backend-free with
  explicit allocator parameters and are unchanged. No spike touched.
- New `test_arena_allocator_end_to_end` (tests/unit/config): resolve +
  errs + describe through one arena, single `free_all` reclaims all.
- Validated: 31/31 unit tests, debug/release Xvfb smokes (exit 0),
  panic path (exit 132, `[PANIC ]` logged), console-only mode, Windows
  cross-build + Wine 11 smoke under `-no-crt` (exit 0). Real desktop
  and real Windows remain the recorded follow-ups.

## M01.02 done (2026-11-12 session)

Generated trusted configuration package (`docs/m01-02-config.md`):

- `src/core/config` (backend-free): schema (SPECS.md §14.2 fonts/theme
  structs, exported fields, bounds), oxocarbon defaults from
  `colorscheme.yaml`, a strict YAML-subset parser (no new dependency),
  resolve/validate/default-fill with owned deep-copied results,
  `generate_source` + atomic `write_staged`, config discovery
  (`--config`/`HAMMER_CONFIG`/per-user path, never project-local).
- Staged package `src/config/generated` (gitignored, regenerated on
  every build, `SCHEMA_VERSION`-asserted); `configs/example.yaml`;
  `--init-config`/`--no-config` make targets; every malformed config
  fails the build with file:line errors (unknown/reserved keys,
  partial themes, bad colors, out-of-range values, tabs).
- `src/main.odin` binds `generated.resolved`; the clear color is the
  configured `theme.body_bg` and the startup log prints the resolved
  summary — config edits visibly change colors after rebuild (M01
  acceptance).
- Tests moved to `tests/unit/config` (13); 30/30 unit tests leak-free.
  Validated: debug/release/run builds, full custom-config pipeline,
  every error path, Windows cross-build + Wine 11 smoke (config under
  `-no-crt`). Traps recorded in `docs/m01-02-config.md` §Traps.

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
