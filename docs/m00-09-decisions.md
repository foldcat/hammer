# M00.09 — Architecture decisions and compatibility inventory

**Status:** done (2026-11-12 session). This is the consolidated record of
every architecture decision taken during M00 and the honest per-platform
status of everything spiked. Each spike doc (`docs/m00-03` … `m00-08`)
remains the authoritative source for how a claim was validated; this file
is the index, the decision log, and the follow-up ledger.

Sources: SPECS.md §1.2 (platform promise) and §18 (M00 acceptance),
`docs/m00-03-window.md` … `docs/m00-08-fuse.md`, `make.odin`,
`.gitmodules`, and spot verifications run this session (versions below).

---

## 1. Decision log

| ID   | Decision                                                                                                                     | Status                   | Revisit trigger                                           |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------ | --------------------------------------------------------- |
| D-01 | **X11 is the product backend** (sokol_app X11/GLX).                                                                          | Active                   | Tier-1 "Linux on Wayland" gate (SPECS.md §1.2)            |
| D-02 | **Windows work deferred at M00** (no toolchain on this machine); M00.03 Windows half unblocked and done via Wine 2026-11-12. | Active (partial unblock) | A Windows toolchain/CI becomes available                  |
| D-03 | **Native Wayland is a documented option, not a commitment.**                                                                 | Deferred option          | Tier-1 Wayland decision due; re-spike on real compositors |
| D-04 | **IPC/FS architecture: canonical local IPC + FUSE/WinFsp mount.**                                                            | Active                   | M19 design work                                           |
| D-05 | **Spikes use raw `core:sys/linux`; no new dependencies (no libfuse).**                                                       | Active                   | M09/M10/M19 implementation                                |

Details:

- **D-01 (2026-11-12, owner).** M00.03 locked in X11 for the current
  pass; the pinned sokol_app has no Wayland backend (verified, M00.06
  Finding 1), so on Wayland sessions the product runs through XWayland —
  verified working (M00.06 Finding 2). Supersedes the original
  "Windows and Linux" wording of M00.03 for this milestone pass.
- **D-02 (2026-11-12, owner; revised 2026-11-12, later session).** No
  Wine and no 32-bit multilib toolchain existed on this machine; building
  one takes hours. The Windows halves of M00.03–M00.08 and the Windows CI
  deliverable were deferred (see §4 for exactly what is blocked). The owner
  then installed Wine 11 and the mingw-w64 cross toolchain (64- and
  32-bit); the M00.03 Windows half was unblocked and executed the same
  day: hammer.exe now cross-builds from Linux (mingw-built Sokol libs,
  lld-link, mingw import libs as the `-windows-sdk-root`) and runs under
  Wine (window, GL, clean shutdown — validated headless). The remaining
  Windows halves (M00.04 clipboard, M00.05 DPI/IME, M00.07 ConPTY,
  M00.08 WinFsp) and the Windows CI runner stay deferred per §4.
- **D-03 (2026-11-12, owner, revised).** The original decision to close
  M00.06 as documentation-only was reversed and the native Wayland spike
  was actually performed. Result: native Wayland is feasible (pinned
  `vendor:glfw` + system libglfw3, M00.06 Finding 3) but stays an option
  for later. Candidate paths, all future decisions: (a) a sokol Wayland
  backend (none exists at the pinned revision), (b) GLFW windowing +
  sokol_gfx over EGL via `glfwGetWaylandDisplay` + `eglGetPlatformDisplay`,
  (c) `vendor:sdl3` (untested). Product path unchanged: sokol/X11.
- **D-04 (design, SPECS.md §16).** Automation is a canonical modern local
  IPC plus an optional live mounted filesystem; the Unix mount half is
  FUSE, the Windows half WinFsp. FUSE deployment risk is now proven
  resolved for Linux (M00.08); WinFsp remains unproven and is a Windows
  deployment dependency (SPECS.md §16.7).
- **D-05 (methodology).** Every M00 spike used the pinned `core:sys/linux`
  (plus pinned `vendor:x11/xlib` and `vendor:glfw` where needed) with no
  new repository dependencies — in particular no libfuse and no shell
  clipboard utilities. The product implementation may revisit this per
  milestone; any new dependency must follow SPECS.md §18/AGENTS.md §18.

## 2. Toolchain and dependency inventory

Pinned (recorded in-repo, verified this session):

| Component      | Pin                                                                                    | Where recorded                                   |
| -------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Odin toolchain | `dev-2026-11` (`/home/user/Builds/odin/odin`)                                          | ROADMAP M00.02; verified `odin version`          |
| Sokol bindings | sokol-odin submodule `ae94aa54d4ecbd7503e299694fa8dc328607d255`                        | `.gitmodules`; `git submodule status`            |
| Sokol C        | floooh/sokol `93aa187b5d387cc24b7290b3ca3f13f61e139e7c`, sha256 `3e5a1b36…785c9`, zlib | `make.odin`; `third_party/sokol-c/SOURCE_COMMIT` |

System (present on this machine, recorded versions; the repo has no
runtime pin for them yet — see follow-ups):

| Component       | Version (this machine)                             | Used by                                                                            |
| --------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| C toolchain     | gcc 16.2.1, binutils 2.47                          | Sokol static-lib build (`make.odin`)                                               |
| X11/GL dev libs | libX11/libXi/libXcursor/libGL dev symlinks present | product + clipboard/DPI spikes                                                     |
| libX11          | 1.8.14                                             | clipboard/DPI/IME spikes; has the `XGetWindowProperty` NULL-out-param bug (M00.04) |
| GLFW            | system libglfw3 3.4.0                              | Wayland spike only — not a product dependency                                      |
| Weston          | 14 (reference compositor, `headless xwayland` USE) | Wayland spike harness                                                              |
| shaderc/glslc   | shaderc-2026.3                                     | not yet pinned (M05.01)                                                            |
| kernel / FUSE   | 6.18.50; FUSE protocol 7.45 offered                | FUSE spike                                                                         |
| fusermount3     | libfuse 3.18.3, setuid root                        | FUSE deployment helper                                                             |
| Mesa            | 26.1.8 (llvmpipe software GL used headless)        | all GL validation                                                                  |

Not yet pinned anywhere (explicit gap; owners below): shader tooling
(`glslc`), font/shaping libraries (FreeType/HarfBuzz) → M05.01;
Tree-sitter → M12.01; WinFsp → M19.05/M20.07. Sokol C sources are fetched
at build time by `make.odin` (sha256-verified) rather than vendored;
`third_party/sokol-c/` is gitignored and carries a `SOURCE_COMMIT`
marker.

## 3. Compatibility matrix (honest status per feature and platform)

Statuses per SPECS.md §19/AGENTS.md §22:
**tested** = implemented and validated headless; **implemented** =
code exists but not runtime-validated; **unsupported** = known gap;
**blocked** = deferred by decision (D-02) or by missing tooling.

| Feature                  | Linux/X11                                                                                                                                         | Linux/Wayland                                                               | Windows                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Window + GL              | **tested** (Xvfb + llvmpipe; real desktop pending)                                                                                                | via XWayland **tested** (M00.06); native via GLFW **tested** (spike only)   | **tested via Wine 11** (cross-build + Xvfb/llvmpipe; real Windows hardware untested) |
| Clipboard                | **tested** headless (UTF-8, INCR 3.2 MiB, TARGETS, no-owner paths)                                                                                | **unsupported** (needs native `wl_data_device`; no `wl-copy` shelling)      | **blocked**                                                                          |
| DPI                      | **tested** (sapp Xft.dpi model, scale 1.0/2.0, high_dpi no-op, mouse coords); per-monitor RandR source **implemented**                            | **unsupported**                                                             | **blocked**                                                                          |
| IME / text input         | XIM commit path (dead-key `é`) **tested**; preedit callbacks **implemented** (no IM server headless); sapp has no XIC hook (pending decision, §5) | **unsupported** (GLFW has no Wayland IME; native needs `zwp_text_input_v3`) | **blocked**                                                                          |
| PTY                      | **tested** (M00.07: spawn, async drain, ANSI chunking, kill, winsize, raw)                                                                        | (terminal/PTY independent of compositor)                                    | **blocked** (ConPTY; no toolchain)                                                   |
| Filesystem mount         | **tested** (M00.08: FUSE mount/readdir/read/statfs, clean + crash lifecycle)                                                                      | (same as X11)                                                               | **blocked** (WinFsp; no toolchain)                                                   |
| Input events (mouse/key) | **tested** (XTEST-fed, sapp CHAR/KEY/MOUSE events)                                                                                                | **implemented** (GLFW callbacks; no injection tool exists on this machine)  | **blocked**                                                                          |
| CI / headless validation | Harnesses exist (Xvfb; nested weston); **no CI config committed**                                                                                 | same                                                                        | **blocked**                                                                          |

Notes behind the matrix:

- **XWayland product path works today** (M00.06 Finding 2): pinned sokol
  under weston 14 + Xwayland, GLX via glamor, clean frames + exit.
- **Wayland headless trap** (M00.06 Finding 4): weston's headless backend
  has no `wl_seat`; pinned GLFW 3.4 segfaults in `glfwInit`. Headless CI
  needs a seated compositor (weston x11-backend in Xvfb).
- **Clipboard on Wayland** needs its own native implementation (M06.04);
  nothing from the X11 spike transfers except the design (UTF-8
  validation, delayed-paste target validation).
- **DPI model consequence** (M00.05): sapp already applies the scale to
  the window/framebuffer/coordinates; the editor must divide
  `sapp.width()` by `sapp.dpi_scale()` for logical layout and track
  RandR itself for mixed-DPI handoffs.
- **IME gap** (M00.05 Finding 2/3): sapp consumes KeyPress without
  `XFilterEvent`; M06.07 must choose: upstream sapp hook, local patch, or
  editor-owned event loop. Decision needed before M06.07 (see §5).
- **FUSE invariants** (M00.08): read buffer ≥ 4096 + max_write;
  fusermount3 new-style protocol (socketpair + `_FUSE_COMMFD` +
  SCM_RIGHTS); option whitelist; crash recovery via `fusermount3 -uz`.

## 4. Windows deferral record (D-02)

Deferred (all blocked by no toolchain on this machine):

- M00.04–M00.08 Windows halves: Win32 clipboard, Windows DPI/IME, ConPTY,
  WinFsp. (M00.03's Windows half was unblocked 2026-11-12 and is done —
  see `docs/m00-03-window.md` §Windows.)
- M00 deliverables "Linux and Windows CI" (Windows part).
- Nothing about Windows behavior is claimed anywhere in the spike docs
  beyond what `docs/m00-03-window.md` records as Wine-validated.

Explicit blocking statement (per SPECS.md §18 M00 acceptance, "a clear
platform limitation either resolves or explicitly blocks the affected
release tier"): **Windows release gates are blocked until a Windows CI
runner exists; the M00.03 Windows build path is now unblocked and
validated under Wine, but the remaining Windows halves (M00.04/05/07/08)
and real-Windows runtime validation still inherit this block.**

Unblock conditions (toolchain half now met): Wine 11 + mingw-w64 (owner
installed, 2026-11-12). Still needed: a Windows CI runner (or equivalent
real-Windows validation) before the remaining spike halves and the
Windows release gates are cleared.

## 5. Consolidated follow-ups (owners and feeds)

Each item is recorded in its spike doc; this is the ledger.

- **M01 / general**
  - Run the product window once on a real X11 desktop (visual output, ESC
    close) — implemented, untested there (m00-03).
  - Commit CI config for the Xvfb/weston harnesses (m00-03, m00-06).
- **M00.03 / Windows build path (2026-11-12)**
  - Build and validate the sokol **D3D11** variant under Wine (the
    product default on Windows; needs `d3d11`/`dxgi`/`d3dcompiler_47`
    imports; GL variant is what is validated today) (m00-03).
  - Validate on real Windows hardware / a Windows CI runner; ESC-close
    path untested under Wine (no input injection) (m00-03).
  - Only `windows_amd64` is buildable: the pinned sokol-odin bindings
    name only `windows_x64_*` libraries (m00-03).
- **M05.01**
  - Pin shader tooling (`glslc`, shaderc-2026.3 present) and FreeType/
    HarfBuzz with licenses (m00-02 gap, m00-03).
- **M06.04 (clipboard)**
  - libX11 1.8.14 dereferences `XGetWindowProperty` out-params
    unconditionally — never pass NULL (m00-04 Finding 2).
  - Decide XA_STRING/COMPOUND_TEXT policy (serve or refuse; never lossy
    silently) (m00-04).
  - Real timestamps instead of `CurrentTime`; fd-based event waiting
    (`XConnectionNumber`) instead of polling, or xcb (m00-04 Findings 4).
  - Per-(requestor, property) INCR queues; `SelectionClear` and
    clipboard-manager takeover handling; UTF-8 validation on receipt
    (m00-04 Findings 1/5/6).
  - Real-desktop + real clipboard manager validation (m00-04).
- **M06.07 (IME)**
  - **Pending decision:** sapp has no XIC/`XFilterEvent` hook →
    upstream hook, local patch, or editor-owned event loop (m00-05).
  - XIM traps to honor: XimLocal keymap caching (remap before IC
    creation), drain MappingNotify + `XRefreshKeyboardMapping` before
    `XOpenIM`, never `XFilterEvent(MappingNotify)`, `XN*` macro strings,
    style-bit values from this Xlib.h, `XTestFlush` in libXext (m00-05).
  - Preedit-callbacks validation against a real IM server (ibus XIM
    bridge) (m00-05).
- **M05.06 / M01.03 (DPI)**
  - Logical/physical conversion rule: divide sapp values by
    `dpi_scale`; editor-owned per-monitor RandR tracking; mixed-DPI
    handoff validation needs a real dual-monitor desktop (m00-05).
- **M09 / M10 (processes/terminal)**
  - Carried from M00.07: TIOCSPTLCK(0) unlock required on PTY open;
    ONLCR/ECHO line-discipline control; chunk-safe ANSI decoding is a
    real requirement (verified split sequences); EIO-on-master
    end-of-output; PDEATHSIG orphan protection; SIGWINCH delivery not
    yet validated.
- **M19.04 (mounted adapter)**
  - Carried from M00.08: unprivileged path = fusermount3 new-style
    protocol (socketpair + `_FUSE_COMMFD` + SCM_RIGHTS; old-style fd
    inheritance rejected); read buffer ≥ 4096 + max_write; option
    whitelist; SYNCFS→ENOSYS acceptable; crash recovery via
    `fusermount3 -uz`; evaluate `auto_unmount` for M19.07.
- **M20.07 (packaging)**
  - Linux runtime prerequisites: `/dev/fuse` + kernel fuse + setuid
    `fusermount3`; Windows: WinFsp installer (deployment dependency,
    SPECS.md §16.7).
- **M20 (release) / Tier-1 Wayland gate**
  - Re-spike against sway/labwc/KDE with an input-injection tool; decide
    among the three native-Wayland options (D-03).

## 6. M00 acceptance review (SPECS.md §18, honest)

| Criterion                                             | Status                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Both Tier-1 OS build paths work                       | **Met (build paths), partial (runtime validation).** Linux/X11: works (build + headless validation). Windows: cross-build works and runs under Wine 11 headless (m00-03 §Windows); real Windows hardware untested — recorded in §4.                                                                             |
| No unverified Wayland/clipboard/IME claim is "solved" | **Met.** Every spike doc separates tested / implemented / unsupported; consolidated in §3.                                                                                                                                                                                                                      |
| Platform limitation resolved or explicitly blocks     | **Met.** Windows deferral explicitly blocks Windows release gates (§4).                                                                                                                                                                                                                                         |
| FS mount deployment risk understood before M19        | **Met.** M00.08 proved the Linux FUSE deployment path, its invariants, and its crash recovery.                                                                                                                                                                                                                  |
| Deliverables                                          | Repo/docs/build baseline/feasibility notes: done. "Linux and Windows CI": Linux harnesses exist, CI config and Windows CI missing (recorded). "IPC and filesystem design decision": SPECS.md §16 + D-04. "Acme compatibility matrix": first cut lives in SPECS.md; the executable matrix is M08.08/M20.01 work. |

M00 is complete except the Windows build-path acceptance item, which is
explicitly blocked and deferred by owner decision rather than silently
dropped. The next milestone (M01) is unblocked on Linux.

## 7. Maintenance

This file is the decision and status ledger for M00. Later milestones
update it (or supersede entries with their own ADRs) when: a decision is
revisited (D-01/D-02/D-03), a dependency is pinned (M05.01/M12.01), a
platform gap closes, or a follow-up is resolved. Statuses in §3 must
never be upgraded without validation runs recorded in the owning spike
doc.
