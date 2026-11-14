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

