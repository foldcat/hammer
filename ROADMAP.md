# ROADMAP.md — Hammer (`hm`)

A modern Acme reimagining in Odin + Sokol.

This file tracks milestone and task status. The plan itself lives in
`SPECS.md` §18 ("Implementation roadmap"); deliverables, dependencies,
and acceptance criteria are defined there and are **not** duplicated
here except as short reminders. When SPECS.md and this file disagree
about _what_ a task is, SPECS.md wins; this file only records _status_.

Per SPECS.md §19.1, exactly one milestone is active at a time. The
active task, allowed scope, and acceptance criteria for the current
session live in `NEXT.md`.

## Status legend

| Mark  | Meaning                                                |
| ----- | ------------------------------------------------------ |
| `[x]` | Done: implemented, tested where applicable, documented |
| `[~]` | In progress                                            |
| `[ ]` | Not started                                            |
| `[!]` | Blocked (see notes)                                    |

"Done" follows SPECS.md §19.4 and AGENTS.md §24: no acceptance-path
stubs, validation actually run, platform claims recorded honestly.

## Milestone overview

| ID  | Title                                              | Depends on     | Release cut | Status      |
| --- | -------------------------------------------------- | -------------- | ----------- | ----------- |
| M00 | Specification, feasibility spikes, build baseline  | —              | —           | Done        |
| M01 | Application shell, platform layer, compiled config | M00            | Alpha A     | **Done**    |
| M02 | Rope, transactions, anchors, headless core         | M01            | Alpha A     | **Active**  |
| M03 | File loading, codecs, safe save, external changes  | M02            | Alpha A     | Not started |
| M04 | Recovery journals, persistent history, shutdown    | M03            | Alpha A     | Not started |
| M05 | Unicode text renderer, fonts, DPI                  | M02 (+M03/M04) | Alpha A     | Not started |
| M06 | Editing input, shortcuts, clipboard, indentation   | M04, M05       | Alpha A     | Not started |
| M07 | Acme columns, windows, tags, mouse, lookup         | M06            | Alpha B     | Not started |
| M08 | Address language, internal commands, Acme Edit     | M07            | Alpha B     | Not started |
| M09 | Asynchronous external commands, selection pipes    | M08            | Alpha B     | Not started |
| M10 | Unicode ANSI console, PTY/ConPTY terminal mode     | M09            | Beta        | Not started |
| M11 | EditorConfig and compiled-config workflow          | M06, M09       | Beta        | Not started |
| M12 | Incremental Tree-sitter highlighting               | M02, M05, M11  | Beta        | Not started |
| M13 | Lightweight buffer completion                      | M06, M12       | Beta        | Not started |
| M14 | Interactive persistent undo tree                   | M04, M07       | Beta        | Not started |
| M15 | Fuzzy finder and project indexing                  | M07, M09       | Beta        | Not started |
| M16 | Persistent per-project layout and restoration      | M04, M07, M15  | Beta        | Not started |
| M17 | Lightweight Git state and change navigation        | M09, M15, M16  | Beta        | Not started |
| M18 | Modern local IPC and command-line client           | M08, M09, M16  | RC          | Not started |
| M19 | Filesystem projection and live FS adapters         | M18            | RC          | Not started |
| M20 | Compatibility completion, hardening, release       | all required   | RC          | Not started |

## Release cuts (SPECS.md §24)

| Cut               | Through | Content                                                                                          |
| ----------------- | ------- | ------------------------------------------------------------------------------------------------ |
| Internal Alpha A  | M06     | Rope, safe save, recovery, undo, fonts, clipboard, modern keyboard input                         |
| Internal Alpha B  | M09     | Columns, tags, mouse/touchpad workflow, Look, Address/Edit, async commands                       |
| Beta              | M17     | ANSI console, EditorConfig, Tree-sitter, completion, history UI, finder, layout, Git indicators  |
| Release candidate | M20     | IPC, filesystem projection/mounts, compatibility hardening, packaging, cross-platform validation |

---

## M00 — Specification, feasibility spikes, and build baseline

**Status:** Done (Windows runtime validation on real hardware remains
deferred by owner decision; see the M00.09 note and
`docs/m00-09-decisions.md` §4).
**Depends on:** —
**Next task:** — (all tasks complete; next milestone is M01.01)

- [x] M00.01 Create repository/docs/agent workflow.
- [x] M00.02 Pin Odin, Sokol, shader tooling, and native dependencies.
- [x] M00.03 Build/run a window (Linux/X11 done; Windows cross-build + Wine validation done 2026-11-12).
- [x] M00.04 Spike Unicode clipboard round-trip and large transfer.
- [x] M00.05 Spike mixed-DPI and text-input/IME integration.
- [x] M00.06 Spike native Wayland feasibility for chosen backend.
- [x] M00.07 Spike PTY/ConPTY and asynchronous process output.
- [x] M00.08 Prove minimal FUSE/WinFsp adapter deployment.
- [x] M00.09 Record architecture decisions and compatibility inventory.

### Notes

- **Allocator migration done (2026-11-12 session).** Owner-directed
  refactor (AGENTS.md §10.5, `docs/m01-alloc-arenas.md`): the product
  now runs on two explicit `core:mem/virtual` arenas in `src/main.odin`
  — a permanent arena (`perm`, one `free_all` at the end of main) and a
  frame-scratch arena (`temp`, reset per frame, installed as
  `context.temp_allocator`); the panic allocator remains only as the
  pre-init sentinel. Validated 31/31 unit tests, debug/release Xvfb
  smokes, panic path, console-only mode, Windows cross-build + Wine 11.
  No spike touched.
- **M01.02 done (2026-11-12 session).** Generated trusted configuration
  package (`docs/m01-02-config.md`): `src/core/config` (schema,
  oxocarbon defaults, strict YAML subset, resolve/validate, source
  generation + atomic staging, config discovery), the gitignored staged
  package `src/config/generated`, `configs/example.yaml`, make.odin
  staging (`--config`, `HAMMER_CONFIG`, `--no-config`, `--init-config`),
  13 new unit tests (30/30 leak-free). Config edits change the compiled
  colors/font size after rebuild (M01 acceptance). Validated debug/
  release/run, all error paths, Windows cross-build + Wine 11. Traps:
  Odin fmt brace escaping, block-scoped defer, relative import
  resolution (`docs/m01-02-config.md` §Traps).
- **M01.03 done (2026-11-12 session).** Logical/physical coordinate
  conversion (`docs/m01-03-coords.md`): backend-free `src/core/coords`
  (distinct `Physical_*`/`Logical_*` types, validated divide/multiply
  conversions, points ↔ logical px per SPECS.md §9.6), consumed by
  `window_metrics` in the app layer. Validated 39/39 unit tests, scale
  1.0/2.0 smokes, real X11 resize events at both scales (throwaway
  resizer), Windows cross-build + Wine 11.
- **M01.04 done (2026-11-12 session).** Native input normalization
  (`docs/m01-04-input.md`): backend-free `src/core/input` (editor `Key`
  naming, modifier/button bit sets, the `Event` tagged union in logical
  coordinates, UTF-32 text validation), sapp adapter in `src/main.odin`
  (keycode table, mask translation, framebuffer→logical conversion,
  cached validated `state.scale`); ESC quit dispatches through a
  normalized `Key_Down`. Validated 45/45 unit tests, XTEST-fed input
  smokes at scale 1.0/2.0 (keys/modifiers/text/buttons/wheel/motion),
  Windows cross-build + Wine 11.
- **M01.05 done (2026-11-12 session).** Bounded worker/result queues
  (`docs/m01-05-queue.md`): backend-free `src/core/queue` — `Queue(T)`
  over caller-owned storage (fixed capacity, zero allocation),
  blocking `push` (backpressure) + `try_push` (`.Full`/`.Closed`
  overflow policy), `pop`/`try_pop`, idempotent `close` (drain-then-
  false). SPECS.md §4.3 revisioned-result contract documented, not
  encoded (M02/M09 own the envelope). Validated 51/51 unit tests
  (MPSC stress with real threads ×10), `-no-crt` Windows cross-build
  of the package + Wine 11 run (exit 0); product smokes unchanged.
- **M01.06 done (2026-11-12 session) — M01 complete.** Basic
  column/tag/body rectangles (`docs/m01-06-render.md`): backend-free
  `src/core/layout` (`Rect`/`Window` geometry, degenerate-size
  collapse, `.Invalid_Input` validation) and the application-layer
  renderer `src/render.odin` (embedded GLSL 410 colored-quad shader,
  write-transient vertex buffer, per-frame layout recompute). A raw-GL
  pixel probe (Linux/X11 test hook) proves headlessly that config
  edits change rendered colors byte-exactly and font-size edits change
  the tag strip height — the M01 acceptance — at scale 1.0/2.0 and
  across live resizes. Validated 57/57 unit tests, debug/release/run
  smokes, Windows cross-build + Wine 11 (renderer running, exit 0).
- **M00.01 done.** Repository skeleton, `AGENTS.md` agent workflow, `SPECS.md`,
  `README.md`, `make.odin` build tool, `colorscheme.yaml`, `ols.json`,
  `.gitignore`/`.gitmodules`. Working tree clean at `3200a42`.
- **M00.02 done.** Verified in-repo pins:
  - Odin toolchain: `dev-2026-11`.
  - Sokol: `third_party/sokol` (sokol-odin) submodule pinned at `ae94aa5`,
    tracking sokol C commit `93aa187`.
  - Open follow-up: shader tooling and native dependency pins
    (FreeType/HarfBuzz/Tree-sitter) are not yet recorded anywhere in the
    repo; record them when M00.03/M05.01 touches them.
- **M00.03 done.** Minimal Sokol window (`src/main.odin`, `sokol_app` +
  `sokol_gfx` + `sokol_glue`) with an `HAMMER_AUTOQUIT_FRAMES` test hook.
  `make.odin` now self-configures Sokol on Linux: fetches the pinned
  floooh/sokol C sources (commit `93aa187`, sha256-verified) into
  `third_party/sokol-c/`, detects missing system deps, and builds the
  static libraries the bindings link against. Validated headless: debug
  and release builds, Xvfb smoke tests (window create, GL clear, clean
  shutdown, exit 0). Docs: `docs/m00-03-window.md`.
- **M00.03 Windows half done (2026-11-12 session).** The owner installed
  Wine 11 and the mingw-w64 cross toolchain, unblocking the toolchain half
  of the D-02 deferral. `odin run make.odin -file -- windows` now
  cross-builds `build/hammer.exe` for `windows_amd64` on Linux: mingw-built
  Sokol GL static libs, a native lld-link (rust-lld shim or
  `ODIN_LLD_PATH`), mingw import libs mirrored into `build/windows-sdk/`
  as the `-windows-sdk-root`, `-no-crt -no-thread-local`. Validated under
  Wine 11 headless (Xvfb + llvmpipe): window create, GL clear, clean
  shutdown, exit 0, debug + release. Traps recorded in
  `docs/m00-03-window.md` §Windows (last-`/defaultlib`-only lld quirk,
  explicit Win32/UCRT import list, `-windows-sdk-root` requirement,
  x64-only bindings naming). D3D11 variant and real-Windows validation
  remain open follow-ups.
- **M00.04 done.** Native X11 clipboard spike (`spike/clipboard/`, built
  by the `clipboard-spike` target in `make.odin`): serve/get modes over
  pinned `vendor:x11/xlib`, `UTF8_STRING` + GTK utf8 atom + `TARGETS`,
  INCR for payloads > 64 KiB, CLIPBOARD and PRIMARY, explicit error
  handling. Validated headless under Xvfb: byte-identical Unicode
  round-trips (400 B and 3.2 MiB/50-chunk INCR on both selections),
  TARGETS listing, no-owner/timeout/usage error paths, and the
  post-exit persistence behavior (data dies with the owner; no clipboard
  manager present). Findings recorded for M00.09/M06.04, including a
  libX11 1.8.14 `XGetWindowProperty` NULL-out-param crash.
  Docs: `docs/m00-04-clipboard.md`.
- **M00.05 done.** Mixed-DPI and text-input/IME spike (`spike/dpi_ime/`,
  built by the `dpi-ime-spike` target): a native probe (Xft.dpi resource,
  mm-based DPI, RandR per-monitor data, XTEST), a sapp probe app, and an
  XIM bridge prototype (`XOpenIM`/`XCreateIC`/`XFilterEvent`/
  `XmbLookupString`) that demonstrates dead-key composition to `é`
  headlessly via XTEST-fed keys. Validated under Xvfb: the pinned sapp's
  X11 DPI model (Xft.dpi-only, `dpi_scale = Xft.dpi/96` always,
  `high_dpi` no-op, pre-scaled window, mouse in framebuffer px), ASCII
  CHAR events, and the XIM commit path. Preedit callbacks are implemented
  but not validatable headless (no IM server; the built-in XIM advertises
  no preedit-callback style) — recorded honestly for M06.07, along with
  integration traps (XimLocal keymap caching, MappingNotify handling,
  XN* string values, Xvfb's last-client state reset).
  Docs: `docs/m00-05-dpi-ime.md`.
- **M00.06 done (2026-11-12 session; decision revised by owner).** The
  Wayland deferral was reversed and the native Wayland feasibility spike
  was actually performed. `spike/wayland/` (GLFW-based: pinned
  `vendor:glfw` + system libglfw3 3.4, installed with the `wayland` USE
  flag) plus `docs/m00-06-wayland.md`. Validated headless: native Wayland
  window + EGL under weston 14 nested in Xvfb (platform auto-selection,
  live `wl_display`/`wl_surface`, GL clear/swap loop, clean autoquit), the
  no-compositor negative path, an X11 contrast run, and the product path —
  pinned-sokol hammer running under weston + Xwayland (X11-only sokol has
  no native Wayland backend; XWayland verified working, GLX via glamor).
  Traps recorded: weston's headless backend advertises no `wl_seat` and
  crashes pinned GLFW 3.4 (headless CI needs a seated compositor, e.g.
  weston x11-backend in Xvfb); Wayland input is implemented but not
  validated headless (no injection tool); GLFW has no Wayland IME
  support. Native-Wayland options for later (sokol backend / GLFW+EGL /
  SDL3) are left as future decisions for M00.09.
- **Decision 2026-11-12 (owner, revised).** X11 remains the locked-in
  backend; a native Wayland spike is now done (M00.06) and native Wayland
  stays a documented option, not a commitment. Windows work remains
  deferred: this machine has no Wine and no 32-bit multilib toolchain,
  and building one takes hours. The Windows halves of M00.03–M00.08 must
  be recorded as deferred in the M00.09 compatibility inventory.
- **M00.07 done.** PTY + asynchronous process output spike (`spike/pty/`,
  `pty-spike` target, `docs/m00-07-pty.md`): raw `core:sys/linux` syscalls,
  no new deps. Verified headless: PTY allocation (TIOCSPTLCK unlock
  required — locked slave opens fail EIO, differentially confirmed vs
  python openpty; grantpt a no-op), fork/execve/setsid/TIOCSCTTY spawn,
  PR_SET_PDEATHSIG, poll-driven non-blocking drain (1 MiB byte-exact, no
  blocked ticks), split ANSI escape reassembly (chunk-safe decoding is a
  real M10.01 requirement), ONLCR/ECHO line-discipline behavior + termios
  raw mode, process-group SIGTERM→SIGKILL escalation with a
  SIGTERM-blocked child, waitpid reaping/exit codes, EIO end-of-output,
  TIOCSWINSZ/TIOCGWINSZ round-trip, no orphaned children. Not validated:
  SIGWINCH delivery, multibyte UTF-8, ConPTY/Windows (no toolchain).
- M00 acceptance (SPECS.md): both Tier-1 OS build paths work; no unverified
  claim about Wayland/clipboard/IME is treated as solved; FS mount deployment
  risk is understood before M19.
- **M00.08 done (2026-11-12 session).** Minimal FUSE deployment proof
  (`spike/fuse/`, `fuse-spike` target, `docs/m00-08-fuse.md`): raw
  `core:sys/linux` FUSE 7.x daemon, no libfuse. Verified headless:
  unprivileged mount via the setuid fusermount3 new-style protocol
  (socketpair + `_FUSE_COMMFD` + SCM_RIGHTS fd handback; direct mount(2)
  EPERM recorded; old-style fd inheritance rejected by fusermount3
  3.18.3), protocol negotiation (kernel 7.45 → 7.31), byte-exact
  multibyte + 280 KB multi-chunk reads through real ls/cat/stat/find/df,
  ENOENT/EROFS paths, SIGTERM clean unmount, kill -9 → kernel abort →
  `fusermount3 -uz` recovery, no leftover mounts. Mounts only in a
  task-owned `mktemp -d` sandbox under /tmp/opencode/. Traps recorded:
  the /dev/fuse read buffer must be ≥ 4096 + max_write (else EINVAL after
  INIT) and the fusermount3 option whitelist. WinFsp/Windows deferred (no
  toolchain).
- **M00.09 done (2026-11-12 session).** Architecture decisions and
  compatibility inventory recorded in `docs/m00-09-decisions.md`:
  decision log (D-01 X11 product backend; D-02 Windows deferred — see
  below; D-03 native Wayland a documented option, not a commitment;
  D-04 IPC+FUSE/WinFsp architecture; D-05 no-new-dependency spikes),
  pinned toolchain/dependency inventory with verified versions,
  honest per-feature per-platform status matrix, the consolidated
  follow-up ledger (all M00.03–M00.08 traps, each with an owning
  milestone), and an M00 acceptance review. Acceptance review result:
  all criteria met except "both Tier-1 OS build paths work" — the
  Windows build path is blocked by the D-02 deferral and explicitly
  blocks Windows release gates; Linux/X11 path works. M00 is marked done
  with that item recorded, not dropped.
- **Windows deferral (D-02, revised 2026-11-12).** Toolchain half
  unblocked (owner installed Wine 11 + mingw-w64 32/64); M00.03 Windows
  half done (cross-build + Wine validation). Still deferred: the Windows
  halves of M00.04–M00.08 (clipboard, DPI/IME, ConPTY, WinFsp), the
  Windows CI deliverable, and real-Windows runtime validation. Unblock:
  a Windows CI runner (owner approval), then re-run the deferred spike
  halves before the relevant milestone gates.

---

## M01 — Application shell, platform layer, and compiled config

**Status:** Done (all six tasks validated headless; real-desktop and
real-Windows validation remain the recorded follow-ups).
**Depends on:** M00
**Next task:** — (milestone complete; next is M02.01)

- [x] M01.01 Implement lifecycle and error-reporting infrastructure.
- [x] M01.02 Add generated trusted configuration package.
- [x] M01.03 Create logical/physical coordinate conversion.
- [x] M01.04 Add native input normalization.
- [x] M01.05 Add worker/result queues with bounded capacity.
- [x] M01.06 Render basic column/tag/body rectangles.

### Notes

- **M01.01 done (2026-11-12 session).** Lifecycle, logging, structured
  errors, and the platform service seam (`docs/m01-01-lifecycle.md`):
  - `src/core/errs` (owned-message structured errors), `src/core/logging`
    (console + bounded file sink, mutex-serialized emission, panic
    reporter installed as `context.assertion_failure_proc`),
    `src/core/lifecycle` (Uninitialized → Initializing → Running →
    Quitting → Shutdown → Exited, idempotent quit, cancel for the M04
    review), `src/platform` (backend-free service interface table;
    Sokol impl lives in `src/main.odin`).
  - Tests moved out of `src/` into `tests/unit/` with the `hammer`
    collection: pinned Odin compiles `_test.odin` files into normal
    builds, which broke the `-no-crt` Windows build via
    `core:testing` → `core:c/libc` (recorded in
    `docs/m00-09-decisions.md` §5). `make.odin -- test` runs 17 tests.
  - Validated: unit tests (sandboxed, leak-checked), Linux debug/release
    Xvfb smokes (exit 0, no leaks at exit), Linux panic path (exit 132,
    panic line in log), console-only mode, Windows cross-build + Wine 11
    smoke (lifecycle + console logging under `-no-crt`), Wine panic path
    (AeDebug auto-exit in the sandbox prefix). Real desktop and real
    Windows hardware remain the recorded M01/D-02 follow-ups.

## M02 — Rope, transactions, anchors, and headless core

**Status:** Active
**Depends on:** M01
**Next task:** M02.05

- [x] M02.01 Implement immutable backing chunks.
- [x] M02.02 Implement leaves, metrics, and range iteration.
- [x] M02.03 Implement balancing and persistent root updates.
- [x] M02.04 Implement coordinate conversion.
- [ ] M02.05 Implement transactions and revision tracking.
- [ ] M02.06 Implement anchor transformation.
- [ ] M02.07 Implement branching in-memory undo.
- [ ] M02.08 Add randomized differential tests and benchmarks.

### Notes

- **M02.04 done (2026-11-13 session).** Coordinate conversion
  (`docs/m02-04-coords.md`): `coord.odin` in `src/core/rope` —
  distinct `Scalar_Index`/`Line_Index`/`Column_Index` types, a shared
  `Coord_Cursor` forward-walk state (scalar decode + pending tail +
  provisional-CR break carry) derived from folded metrics, O(depth)
  descents (byte/scalar first-own/break resolved rules) with at most
  one piece decoded per conversion. Byte↔scalar, byte→line,
  line start/end, line/column↔byte/scalar, all bounds-validated;
  grapheme positions deferred to M05.02. 5 new coord tests (24 in the
  package) incl. a 400-step differential comparing every conversion
  at every position against an independent linear-scan model — it
  caught a real tree bug (document offsets mixed with chunk offsets →
  non-monotonic scalar_to_byte) and two reference-model bugs.
  Validated 24/24 leak-free ×10, full suite 89 tests clean,
  debug/release builds, Xvfb release smoke, `-no-crt` Windows
  cross-build + Wine 11 consumer (round-trips, exit 0). No product
  consumer yet (M02.05).
- **M02.03 done (2026-11-12 session).** Balancing and persistent root
  updates (`docs/m02-03-tree.md`): `tree.odin` in `src/core/rope` — a
  persistent copy-on-write B-tree (`Node` kind-tagged leaf/internal,
  single intrusive-link pool, `Tree` root+revision). Inserts splice
  interned pieces and cascade leaf repacks + balanced internal splits;
  deletes split boundary pieces, drop emptied leaves, merge under-full
  internal children left-first, and collapse single-child roots;
  snapshots stay byte-identical via `tree_read_root(_all)`;
  `tree_check` validates bounds/depth/pieces/metrics. 8 new tree tests
  (19 in the package) incl. a 500-step differential (content + metrics
  vs `metrics_of` and the independent oracle + invariants + revision +
  span iteration + snapshot probes) that caught three real bugs:
  fixed-array slices including zeroed entries, a sibling-merge
  ordering scramble (also the cause of a segfault), and a missing
  `combine` leading-run carry. Validated 19/19 leak-free ×10, full
  suite 84 tests clean, debug/release builds, Xvfb release smoke,
  `-no-crt` Windows cross-build + Wine 11 consumer (snapshot
  persistence, exit 0). No product consumer yet (M02.05).
- **M02.02 done (2026-11-12 session).** Leaves, metrics, and range
  iteration (`docs/m02-02-leaves.md`): backend-free `src/core/rope` —
  `Piece` over chunk ids, pool-allocated `Leaf`s (≤8 inline pieces +
  local metrics, `core:container/pool` with intrusive link), the flat
  `Sequence` (leaf list + totals, target leaf size, append-only
  builder), boundary-aware `Metrics`/`combine` (multi-byte scalars and
  CRLF split across pieces count once, incl. a tail-carry case), and
  flatten-free `read`/`read_all`/`Span_Iter`. Plus a non-asserting
  `chunk.lookup` for piece validation. 11 new unit tests incl. a
  300-step differential property checked against both `metrics_of` of
  the flattened reference and an independent oracle implementation
  (caught two real combine/decode bugs). 76 tests total leak-free;
  debug/release builds; Xvfb release smoke; `-no-crt` Windows
  cross-build + Wine 11 consumer run (exit 0). No product consumer
  yet (M02.05 wires the buffer registry).
- **M02.01 done (2026-11-12 session).** Immutable backing chunks
  (`docs/m02-01-chunks.md`): backend-free `src/core/chunk` — a `Store`
  of immutable, content-interned (hash-consed) chunks with stable
  `Chunk_ID`s (SPECS.md §7.1 ByteStore layer). `insert` splits input
  into `chunk_size` chunks and returns the caller-owned id list;
  `data` returns store-lifetime borrowed views; interning uses a
  hand-rolled open-addressing table (the pinned Odin has no
  `core:map`); allocation failures are `.Resource_Limit` with the
  store left consistent. 9 new unit tests (incl. failure injection
  and a 300-step differential property vs a linear-scan reference
  model), all leak-free; full suite clean; debug/release builds;
  Xvfb release smoke; `-no-crt` Windows cross-build + Wine 11
  consumer run (exit 0). No product consumer yet (M02.02 wired the
  rope builder; M02.05 wires the buffer registry).

## M03 — File loading, codecs, safe save, and external changes

**Status:** Not started
**Depends on:** M02

- [ ] M03.01 Implement canonical file identity.
- [ ] M03.02 Implement background chunked loading.
- [ ] M03.03 Implement UTF-8/BOM/newline policy.
- [ ] M03.04 Implement explicit unsupported/invalid encoding behavior.
- [ ] M03.05 Implement temporary-write/replace save.
- [ ] M03.06 Implement disk-change conflict detection.
- [ ] M03.07 Add failure-injection tests for save.

## M04 — Recovery journals, persistent history foundation, and shutdown guard

**Status:** Not started
**Depends on:** M03

- [ ] M04.01 Implement versioned checksummed journal.
- [ ] M04.02 Implement periodic checkpointing and rotation.
- [ ] M04.03 Implement crash recovery discovery.
- [ ] M04.04 Implement stale-session/lock detection.
- [ ] M04.05 Persist undo transactions and branches.
- [ ] M04.06 Implement dirty-buffer close/quit decisions.
- [ ] M04.07 Implement save-failure exit blocking.
- [ ] M04.08 Add kill-at-random-point recovery tests.

## M05 — Unicode text renderer, fonts, and DPI

**Status:** Not started
**Depends on:** M02; integrates M03/M04

- [ ] M05.01 Bind and pin font/shaping/Unicode libraries.
- [ ] M05.02 Implement font discovery and role selection.
- [ ] M05.03 Implement glyph atlas/cache lifecycle.
- [ ] M05.04 Implement shaping and positioned runs.
- [ ] M05.05 Implement selection/caret hit testing from shaped runs.
- [ ] M05.06 Implement DPI change invalidation.
- [ ] M05.07 Implement huge-line bounded rendering.
- [ ] M05.08 Add mixed-script/DPI visual fixtures.

## M06 — Editing input, modern shortcuts, clipboard, and indentation

**Status:** Not started
**Depends on:** M04, M05

- [ ] M06.01 Implement movement and selection actions.
- [ ] M06.02 Implement keyboard binding resolver.
- [ ] M06.03 Implement text-input versus key-command separation.
- [ ] M06.04 Implement native clipboard service on both OS families.
- [ ] M06.05 Implement delayed-paste target validation.
- [ ] M06.06 Implement multiline indent/outdent transaction.
- [ ] M06.07 Implement IME preedit/commit handling.
- [ ] M06.08 Add clipboard interoperability tests.

## M07 — Acme columns, windows, tags, mouse workflow, and lookup

**Status:** Not started
**Depends on:** M06

- [ ] M07.01 Implement columns/window layout and dragging.
- [ ] M07.02 Implement buffer/view separation in UI.
- [ ] M07.03 Implement tag editing and generated command state.
- [ ] M07.04 Implement original mouse actions/chords.
- [ ] M07.05 Implement modifier-assisted gestures.
- [ ] M07.06 Implement Look token expansion and file opening.
- [ ] M07.07 Implement directory windows and error windows.
- [ ] M07.08 Add compatibility scenarios for window behavior.

## M08 — Address language, internal commands, and Acme Edit

**Status:** Not started
**Depends on:** M07

- [ ] M08.01 Implement command dispatch and context.
- [ ] M08.02 Implement line/character/range addresses.
- [ ] M08.03 Implement compatible regex address semantics.
- [ ] M08.04 Implement documented Edit command subset in dependency order.
- [ ] M08.05 Complete required Edit coverage.
- [ ] M08.06 Add cancellable snapshot-based execution for expensive edits.
- [ ] M08.07 Implement atomic multi-buffer validation where needed.
- [ ] M08.08 Add differential compatibility fixtures.

## M09 — Asynchronous external commands and selection pipes

**Status:** Not started
**Depends on:** M08

- [ ] M09.01 Implement process spawning and handle ownership.
- [ ] M09.02 Implement nonblocking stdin/stdout/stderr flow.
- [ ] M09.03 Implement job lifecycle and Stop command.
- [ ] M09.04 Implement contextual environment/cwd.
- [ ] M09.05 Implement output-window batching/backpressure.
- [ ] M09.06 Implement selection stdin/output replacement.
- [ ] M09.07 Implement stale-target conflict behavior.
- [ ] M09.08 Integrate running-job quit decisions.

## M10 — Unicode ANSI console and PTY/ConPTY terminal mode

**Status:** Not started
**Depends on:** M09

- [ ] M10.01 Implement chunk-safe UTF-8 decoder.
- [ ] M10.02 Implement ANSI state machine and SGR styles.
- [ ] M10.03 Implement CR/backspace/erase progress behavior.
- [ ] M10.04 Implement hyperlink/control-sequence safety policy.
- [ ] M10.05 Implement PTY/ConPTY process mode.
- [ ] M10.06 Integrate a tested terminal-emulation layer.
- [ ] M10.07 Implement resize, alternate screen, and raw input.
- [ ] M10.08 Test advertised terminal capabilities.

## M11 — EditorConfig and polished compiled-config workflow

**Status:** Not started
**Depends on:** M06, M09

- [ ] M11.01 Implement tested EditorConfig resolution.
- [ ] M11.02 Apply indentation settings.
- [ ] M11.03 Apply explicit EOL/charset save policies.
- [ ] M11.04 Implement undoable trailing-space/final-newline formatting.
- [ ] M11.05 Add asynchronous config-build command.
- [ ] M11.06 Add staged restart/handoff.
- [ ] M11.07 Add config validation/diagnostics.

## M12 — Incremental Tree-sitter highlighting

**Status:** Not started
**Depends on:** M02, M05, M11

- [ ] M12.01 Pin runtime/bindings/initial grammars.
- [ ] M12.02 Implement rope-backed TSInput.
- [ ] M12.03 Convert transactions to parser edits.
- [ ] M12.04 Implement worker-owned incremental trees.
- [ ] M12.05 Implement revisioned highlight publication.
- [ ] M12.06 Implement invalidation and query scope expansion.
- [ ] M12.07 Add initial language set and plain-text fallback.
- [ ] M12.08 Add parser budget/cancellation tests.

## M13 — Lightweight buffer completion

**Status:** Not started
**Depends on:** M06, M12

- [ ] M13.01 Implement word-boundary token extraction.
- [ ] M13.02 Implement incremental count/index updates.
- [ ] M13.03 Implement ranking and bounded result count.
- [ ] M13.04 Implement popup input/focus rules.
- [ ] M13.05 Implement completion transaction.
- [ ] M13.06 Implement large-file limits.

## M14 — Interactive persistent undo tree

**Status:** Not started
**Depends on:** M04, M07

- [ ] M14.01 Expose history model to a special buffer/view.
- [ ] M14.02 Render textual/visual branch tree.
- [ ] M14.03 Implement jump/preview actions.
- [ ] M14.04 Persist labels/checkpoints/branch selection.
- [ ] M14.05 Validate history against reopened disk content.
- [ ] M14.06 Implement orphaned-history handling.
- [ ] M14.07 Implement safe budget/pruning policy.

## M15 — Fuzzy finder and project indexing

**Status:** Not started
**Depends on:** M07, M09

- [ ] M15.01 Implement bounded project traversal.
- [ ] M15.02 Implement ignore and symlink policy.
- [ ] M15.03 Implement fuzzy ranking/highlight spans.
- [ ] M15.04 Implement finder overlay/special window.
- [ ] M15.05 Implement preview and open actions.
- [ ] M15.06 Implement incremental refresh/cancellation.
- [ ] M15.07 Benchmark large-project queries.

## M16 — Persistent per-project layout and session restoration

**Status:** Not started
**Depends on:** M04, M07, M15

- [ ] M16.01 Serialize columns/window order and ratios.
- [ ] M16.02 Serialize view anchors and tags.
- [ ] M16.03 Persist scratch/recovery references.
- [ ] M16.04 Implement debounced safe writes.
- [ ] M16.05 Implement restore with missing-file states.
- [ ] M16.06 Implement schema migration/fallback.
- [ ] M16.07 Implement explicit project relocation.

## M17 — Lightweight Git state and change navigation

**Status:** Not started
**Depends on:** M09, M15, M16

- [ ] M17.01 Detect repository/worktree context.
- [ ] M17.02 Parse machine-readable status safely.
- [ ] M17.03 Compute file/index/HEAD baseline metadata.
- [ ] M17.04 Compute unsaved-buffer change hunks.
- [ ] M17.05 Render compact markers and tag status.
- [ ] M17.06 Implement hunk navigation.
- [ ] M17.07 Add debounce/cancellation and non-Git fallback.

## M18 — Modern local IPC and command-line client

**Status:** Not started
**Depends on:** M08, M09, M16

- [ ] M18.01 Implement framing/version negotiation.
- [ ] M18.02 Implement local authorization/ACLs.
- [ ] M18.03 Implement read/list/create operations.
- [ ] M18.04 Implement revisioned mutation operations.
- [ ] M18.05 Implement chunked text transfer.
- [ ] M18.06 Implement event stream/sequence handling.
- [ ] M18.07 Implement interception/reinjection lease state.
- [ ] M18.08 Implement acmectl and script examples.
- [ ] M18.09 Add disconnect/abuse/conflict tests.

## M19 — Filesystem projection and live filesystem adapters

**Status:** Not started
**Depends on:** M18

- [ ] M19.01 Implement revisioned ordinary-file projections.
- [ ] M19.02 Implement atomic request mailbox and replies.
- [ ] M19.03 Implement event retention/gap reporting.
- [ ] M19.04 Implement Unix mounted adapter.
- [ ] M19.05 Implement Windows mounted adapter.
- [ ] M19.06 Implement per-open addr/data/event semantics.
- [ ] M19.07 Implement safe cancellation/unmount/shutdown.
- [ ] M19.08 Add shell-based read/write/execute examples.
- [ ] M19.09 Add filesystem compatibility tests.

## M20 — Compatibility completion, hardening, packaging, release

**Status:** Not started
**Depends on:** all required milestones

- [ ] M20.01 Close required Acme compatibility gaps.
- [ ] M20.02 Run full cross-platform integration matrix.
- [ ] M20.03 Run performance and large-file benchmarks.
- [ ] M20.04 Run crash/disk-error/clipboard stress tests.
- [ ] M20.05 Audit resource ownership and cancellation.
- [ ] M20.06 Audit dependency licenses and packaging.
- [ ] M20.07 Package runtime/native FS dependencies.
- [ ] M20.08 Document limitations and migration.
- [ ] M20.09 Prepare release candidate and soak testing.
