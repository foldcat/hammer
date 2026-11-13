# What to do?

Work through the active milestone one task per session, in order. Write
your documentation in `/docs`.

## Current task: M02.08 — Randomized differential tests and benchmarks

M02.01–M02.07 are done; M02 (SPECS.md §18) is active. M02.08 closes
the milestone's test matrix: randomized differential coverage for the
whole rope/txn stack (SPECS.md §7.7 property matrix, the M02.02–M02.07
differential discipline — independent reference models, xorshift64
seeds, no flakes) plus bounded benchmarks (no whole-buffer copies for
small edits; no flattening — SPECS.md §7.6). The headless-core rule
(SPECS.md §4.2) applies.

Required reading for new code in `src/`: the traps in
`docs/m01-02-config.md` §Traps, `docs/m01-03-coords.md` §Traps,
`docs/m01-04-input.md` §Traps, `docs/m01-05-queue.md` §Traps,
`docs/m01-06-render.md` §Traps, `docs/m02-01-chunks.md` §Traps,
`docs/m02-02-leaves.md` §Traps, `docs/m02-03-tree.md` §Traps,
`docs/m02-04-coords.md` §Traps, `docs/m02-05-transactions.md` §Traps,
`docs/m02-06-anchors.md` §Traps, and `docs/m02-07-undo.md` §Traps
(never copy a Doc/Tree/Store; reference models replay the applied
order; empty-range replace is a pure insert; no local type
declarations; no `core:map`; a no-op apply creates no node; `make`
with a length pre-fills).

## M02.07 done (2026-11-13 session)

Branching in-memory undo (`docs/m02-07-undo.md`) — the SPECS.md §8.4
undo tree over the M02.05 log:

- The log **is** the tree: `Log_Entry` gained parent/child ids,
  timestamp (`core:time`, CRT-free), and before/after selection state;
  `Doc` gained `current` (node id, 0 = initial state) and a global
  `next_revision` counter (branching breaks `after = base + 1`, but
  revisions stay unique — the §4.3 stale-rejection contract is
  untouched). `doc_apply` links the new node under the current one
  (all-or-nothing: selection validation, op copy, log reserve, and
  parent-children reserve all roll the root back; the children append
  is the final step). `doc_check` validates the tree: dense ids,
  strictly increasing revisions, parent/child symmetry, base/before-
  root/before-selection vs the parent, current state vs tree root,
  counters.
- New `undo.odin`: `Selection` (anchor/active/affinity/visual column,
  bounds-validated at apply), `doc_undo`/`doc_redo` (pointer-only
  state jumps, no allocation), `doc_undoable`/`doc_redoable`;
  `.NotFound` added to errs for the boundary cases. Grouping via the
  M02.05 `grouping_key`: a maximal run of consecutive nodes sharing a
  nonzero key is one undo unit in both directions. Undo + new edit
  creates a sibling; the abandoned branch and its snapshots survive;
  redo follows the most recently applied child. `anchor_transform`
  revised to replay the current path; anchors on abandoned branches
  are `.Conflict` (never silently transformed).
- `tests/unit/txn/undo_test.odin` added (7 tests; 18 in the package):
  linear undo/redo with selection restore, branching retention, group
  undo/redo, selection recording/validation, timestamp sandwich,
  anchors across branches, and a 600-step randomized differential
  (apply/undo/redo with random groups and selections + an anchor pool
  vs an independent reference tree, mirroring every step). The
  differential caught two test-side bugs (a zero-padded reference
  clone; an all-colliding empty-op step that is a doc no-op).
- Validated: 18/18 txn tests leak-free (×10, no flake; also
  single-threaded); full suite via `odin run make.odin -file -- test`
  (108 tests, all 12 test-bearing packages clean); debug/release
  builds; Xvfb release smoke (exit 0, no PANIC/ERROR); `-no-crt`
  Windows cross-build of a throwaway consumer + Wine 11 run (group
  undo/redo, branching, stale/abandoned-anchor conflicts, path
  transform, doc_check, exit 0). No product consumer yet (M06 wires
  selections and grouping keys; M03/M04 add file identity and
  persistence).

## M02.06 done (2026-11-13 session)

Anchor transformation (`docs/m02-06-anchors.md`) — the SPECS.md §8.3
stable-position primitive over the M02.05 log:

- New `anchor.odin` in `src/core/txn`: `Affinity` (Left sticks to the
  left text — inserts at the anchor push it past; Right sticks to the
  right text — it stays put), `Anchor` (pos + affinity + captured
  revision), `anchor_at` (validated capture at the current revision),
  `anchor_transform` (replays log entries with base ≥ the anchor's
  revision in the applied order; stamps the current revision;
  idempotent at the current revision; `.Invalid_Input` for anchors
  ahead of the document). Delete collapse rules and the replace
  range-end adjacency rule documented and pinned.
- `tests/unit/txn/anchor_test.odin` added (5 tests; 11 in the
  package): affinity/delete/replace hand cases, log replay across
  revisions, and a 400-step randomized differential (a pool of anchors
  at random revisions/positions/affinities vs an independent reference
  transform) that caught two reference-model bugs (unsorted replay
  order; empty-range replace misrule) and a test bug worth recording
  (copying a Doc by value — never do that).
- Validated: 11/11 txn tests leak-free (×10, no flake); full suite
  via `odin run make.odin -file -- test` (100 tests, all 11
  test-bearing packages clean); debug/release builds; Xvfb release
  smoke (exit 0, no PANIC/ERROR); `-no-crt` Windows cross-build of a
  throwaway consumer + Wine 11 run (both affinities through a
  multi-op transaction, stale rejection, exit 0). No product consumer
  yet (M06 selections).

## M02.05 done (2026-11-13 session)

Transactions and revision tracking (`docs/m02-05-transactions.md`) —
the SPECS.md §8.1 transaction layer over the persistent rope:

- New backend-free `src/core/txn`: `Doc` (chunk store + tree +
  transaction-level revision + applied log) where `doc_apply` is the
  only mutation path. `Transaction` (id assigned on apply, source
  enum, base_revision, grouping_key, ops) with `Operation` =
  Insert/Delete/Replace in base-snapshot coordinates: validated
  (bounds, no overlapping ranges, no duplicate insert positions) and
  applied in deterministic descending order (delete/replace before an
  insert at the same position) so every original offset stays valid.
  Stale base revisions are `.Conflict` with no mutation (SPECS.md
  §4.3); failed applies roll back the root (and the revision/id when
  the log copy fails) — all-or-nothing. The log records every applied
  transaction with before/after roots and an owned op copy (the M02.06
  anchor / M02.07 undo substrate); `doc_check` validates tree
  invariants plus the log chain.
- `tests/unit/txn` added (6 tests): basic applies with per-entry
  snapshot-root verification, stale rejection, multi-op ordering
  (four input orders → identical content), validation rejections,
  atomic rollback via a fixed-arena log-copy failure, and a 400-step
  randomized differential with periodic stale probes.
- Validated: 6/6 txn tests leak-free (×10, no flake); full suite via
  `odin run make.odin -file -- test` (95 tests, all 11 test-bearing
  packages clean); debug/release builds; Xvfb release smoke (exit 0,
  no PANIC/ERROR); `-no-crt` Windows cross-build of a throwaway
  consumer + Wine 11 run (multi-op transaction, stale `.Conflict`,
  doc_check clean, exit 0). No product consumer yet.

## M02.04 done (2026-11-13 session)

Coordinate conversion (`docs/m02-04-coords.md`) — the SPECS.md §7.3
byte/scalar/line/column layer over the persistent tree:

- New `coord.odin` in `src/core/rope`: distinct `Scalar_Index`/
  `Line_Index`/`Column_Index` types; a shared `Coord_Cursor`
  forward-walk state (scalar decode with pending tail + break counter
  with provisional-CR carry) derived from folded metrics so subtree
  skips and piece decodes agree exactly with `metrics_of`/`combine`;
  O(depth) descents by byte offset, scalar index (first-own rule), and
  break index (resolved-break rule); at most one piece decoded per
  conversion — no flattening. `tree_byte_to_scalar`/
  `tree_scalar_to_byte`/`tree_byte_to_line`/`tree_line_start(_end)`/
  `tree_byte_to_line_col`/`tree_line_col_to_byte` (+ scalar variants),
  `tree_scalar_count`/`tree_line_count`, all bounds-validated. Grapheme
  positions explicitly deferred to M05.02 (segmentation context).
- `tests/unit/rope/coord_test.odin` added (5 tests; 24 in the
  package): hand-computed cases, empty-tree edges, bounds errors,
  round-trip properties, and a 400-step randomized differential
  comparing every conversion at every position against an independent
  linear-scan model. The differential caught a real tree bug
  (document offsets mixed with chunk offsets → non-monotonic
  scalar_to_byte) and two reference-model bugs (CR-resolution order,
  stale line_count).
- Validated: 24/24 rope tests leak-free (×10, no flake); full suite
  via `odin run make.odin -file -- test` (89 tests, all packages
  clean); debug/release builds; Xvfb release smoke (exit 0, no
  PANIC/ERROR); `-no-crt` Windows cross-build of a throwaway consumer
  + Wine 11 run (coordinate round-trips, known positions exact, exit
  0). No product consumer yet (M02.05 wires the buffer registry).

## M02.03 done (2026-11-12 session)

Balancing and persistent root updates (`docs/m02-03-tree.md`) — the
SPECS.md §7.1 Internal node / RopeRoot layer:

- New `tree.odin` in `src/core/rope`: a persistent copy-on-write
  B-tree — one kind-tagged `Node` type (leaf pieces or internal
  children, both inline) from a single `core:container/pool` (intrusive
  link; nodes never recycled while any root references them), `Tree`
  (root + revision). Inserts splice interned pieces (boundary piece
  split) and cascade leaf repacks and balanced internal splits;
  deletes split boundary pieces (a same-piece split can leave 9
  survivors → leaf splits), drop emptied leaves, merge under-full
  internal children left-sibling-first, and collapse single-child
  roots. Old roots stay byte-identical (`tree_read_root(_all)`);
  revision bumps exactly once per successful mutation. `tree_check`
  validates bounds, uniform leaf depth, piece validity, and metric
  recomputation; span iteration walks snapshot roots.
- `tests/unit/rope/tree_test.odin` added (8 tests; 19 total in the
  package): build/insert/delete vs the reference model, full-leaf
  split cases, snapshot persistence across edit rounds, validation
  errors, and a 500-step seeded differential (content + metrics vs
  `metrics_of` AND the independent oracle + invariants + revision +
  span iteration + snapshot probes after every op). The differential
  caught three real bugs inspection missed: fixed-array slices
  including zeroed entries, a sibling-merge ordering scramble (which
  also caused a segfault), and a missing `combine` leading-run carry.
- Validated: 19/19 rope tests leak-free (×10 runs, no flake; also
  single-threaded); full suite via `odin run make.odin -file -- test`
  (84 tests, all packages clean); debug/release builds; Xvfb release
  smoke (exit 0, no PANIC/ERROR); `-no-crt` Windows cross-build of a
  throwaway consumer + Wine 11 run (snapshot persistence, revision
  accounting, tree_check clean, exit 0). No product consumer yet
  (M02.05 wires the buffer registry).

## M02.02 done (2026-11-12 session)

Leaves, metrics, and range iteration (`docs/m02-02-leaves.md`) — the
SPECS.md §7.1 Piece/Leaf/local-metrics layer on top of M02.01:

- New backend-free `src/core/rope`: `Piece` (store_id + byte_start +
  byte_length over chunk ids), pool-allocated `Leaf` (≤ 8 inline
  pieces + local `Metrics`; `core:container/pool` with an intrusive
  `link` field — stable pointers, libc-free), `Sequence` (leaf list +
  totals + target leaf size, append-only builder closing leaves by
  piece count or byte bound), `Metrics`/`Boundary` with exact
  boundary-aware `combine` (multi-byte scalars and CRLF split across
  piece boundaries count once, including a tail-carry case for
  all-continuation runs), and flatten-free range reads: `read`
  (caller-buffered partial fills), `read_all`, and a `Span_Iter`
  yielding borrowed chunk slices. `.Invalid_Input` for bad ranges and
  pieces (via a new non-asserting `chunk.lookup`), `.Resource_Limit`
  for allocation failure with the sequence left consistent.
- `tests/unit/rope` added (11 tests): hand-checked metrics cases,
  combine split-invariance at every split point (incl. invalid lead
  sequences), tail-carry/broken-completion merges, append+flatten,
  leaf splitting (piece count and byte bound) with per-leaf metrics
  recomputation, partial reads, span iteration, validation errors,
  arena lifetime, allocation-failure injection, and a 300-step seeded
  differential property checked against BOTH `metrics_of` of the
  flattened reference AND an independent oracle implementation (the
  differential test caught two real combine/decode bugs that inspection
  and single-implementation checks missed).
- Validated: 11/11 rope tests leak-free (×5, no flake); full suite via
  `odin run make.odin -file -- test` (76 tests, all packages clean);
  debug/release builds; Xvfb release smoke (exit 0, no PANIC/ERROR);
  `-no-crt` Windows cross-build of a throwaway consumer + Wine 11 run
  (multibyte+CRLF split-chunk round-trip, metrics, exit 0). No product
  consumer yet (M02.05 wires the buffer registry).

## M02.01 done (2026-11-12 session)

Immutable backing chunks (`docs/m02-01-chunks.md`) — the SPECS.md §7.1
ByteStore layer, the foundation the rest of M02 builds on:

- New backend-free `src/core/chunk`: `Store` owning immutable,
  content-interned (hash-consed) byte chunks with stable `Chunk_ID`s.
  `insert` splits input into `chunk_size` chunks (overflow-free) and
  returns the id list (caller-owned); `data` returns borrowed views
  stable for the store's lifetime; `destroy` releases everything
  (arena-compatible no-op frees). Interning is a hand-rolled
  open-addressing table (load ≤ 3/4, `h|1` hashes, byte-compare
  collision resolution) — the pinned Odin has **no `core:map`**.
  Allocation failures surface as `.Resource_Limit` and leave the store
  consistent; error messages use the caller's allocator, never the
  store's.
- `tests/unit/chunk` added (9 tests): split/round-trip, dedup across
  and within inserts, empty/nil edges, view stability across table
  growth, constant-hash collision path, buffer-arena allocation-failure
  injection, growing-arena end-to-end reclaim, and a 300-step seeded
  differential property against a linear-scan reference model.
- Validated: 9/9 chunk tests leak-free (×5, no flake); full suite via
  `odin run make.odin -file -- test` (all packages clean); debug/release
  builds; Xvfb release smoke (exit 0, clean lifecycle); `-no-crt`
  Windows cross-build of a throwaway consumer + Wine 11 run (multibyte
  round-trip, dedup, exit 0). No product consumer yet (M02.02 wires the
  rope builder) — matches the M01.05 queue precedent.

## Build tool fix (2026-11-12 session)

`odin run make.odin -file -- run` no longer buffers the app's output:
`run_odin` captured stdout/stderr with `os.process_exec` (which asserts
the desc streams are nil and can only replay after the child exits), so
every runtime log line appeared only once the window was closed. The
`run` target now uses `os.process_start` with `stdout = os.stdout` /
`stderr = os.stderr` so logs stream live; build/test targets keep the
capture path. Verified live under Xvfb (wrapper stdout had `[INFO]`
lines while the app was still running) plus 57/57 unit tests and the
`build` capture path.

## M01 done (2026-11-12 session, M01.06)

Render basic column/tag/body rectangles (`docs/m01-06-render.md`) —
this closes M01:

- New backend-free `src/core/layout`: `Rect`/`Window` (frame/tag/body)
  geometry with degenerate-size collapse and `.Invalid_Input`
  validation; `src/render.odin` (application layer) draws them with
  sokol_gfx (embedded GLSL 410 colored-quad shader, write-transient
  vertex buffer), recomputing the layout every frame from the window
  metrics, cached scale, and configured theme/font size.
- New render probe test hook (Linux/X11, raw-GL readback): proves
  headlessly, byte-exactly, that config edits change rendered colors
  and font sizes change the tag strip height — the M01 acceptance —
  at scale 1.0/2.0, after live resizes, debug and release.
- Validated: 57/57 unit tests leak-free (layout 6 new); pixel probes
  (default config `tag=#262626 body=#161616`; custom config
  `tag=#446688 body=#112233`; 21pt font flips the below-tag sample);
  Windows cross-build + Wine 11 smoke with the renderer running
  (exit 0). Real-desktop visual check remains the standing follow-up.

M01 overall status: all six tasks done and validated headless;
real-desktop and real-Windows validation stay recorded as the M01/D-02
follow-ups.

## M01.05 done (2026-11-12 session)

Worker/result queues with bounded capacity (`docs/m01-05-queue.md`):

- New backend-free `src/core/queue`: `Queue(T)` ring buffer over
  caller-owned storage (capacity fixed at init, zero allocation
  after), `push` (blocking backpressure) / `try_push` (overflow
  policy: `.Full`/`.Closed`), `pop`/`try_pop`, `close` (idempotent
  cancellation: pushes fail, waiters wake, drain-then-false),
  `capacity`/`count`/`is_closed`. Mutex + two cond vars; `core:sync`
  only (libc-free on both platforms).
- SPECS.md §4.3 revisioned-result contract documented on the package,
  deliberately not encoded (no dead envelope types; M02/M09 own the
  envelope).
- `tests/unit/queue` added (6 tests: FIFO/capacity, wrap-around,
  close, backpressure thread test, close-wakeup thread test, 4×250
  MPSC stress). Validated: 51/51 unit tests leak-free, stress tests
  run 10× without a flake, throwaway consumer cross-built for
  windows_amd64 under `-no-crt` and run under Wine 11 (exit 0);
  product debug/release/run/windows/panic smokes unchanged.

## M01.04 done (2026-11-12 session)

Native input normalization (`docs/m01-04-input.md`):

- New backend-free `src/core/input`: editor-owned `Key` naming (119
  members), `Modifiers`/`Mouse_Button(s)` bit sets, the `Event` tagged
  union (key down/up, text, pointer down/up/move, scroll — logical
  coordinates), `normalize_text` (UTF-32 validation, never asserts on
  backend data), `describe` diagnostics with a pinned format.
- `src/main.odin` adapter: sapp keycode table, modifier/button mask
  translation, `normalize_sapp_event` (framebuffer→logical via
  `core/coords`), `state.scale` cache (validated once in
  `window_metrics`); ESC quit now dispatches through a normalized
  `Key_Down`. `tests/unit/input` added (6 tests).
- Validated: 45/45 unit tests leak-free; headless XTEST-fed input
  smokes at scale 1.0 and 2.0 (keys, modifiers, text, buttons, wheel,
  motion → logical coords, ESC-quit exit 0); debug/release/run smokes;
  panic path (132); Windows cross-build + Wine 11 smoke (exit 0). Real
  desktop, IME/dead keys, and real Windows input remain the recorded
  follow-ups.

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
