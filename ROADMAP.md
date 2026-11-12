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
| M00 | Specification, feasibility spikes, build baseline  | —              | —           | **Active**  |
| M01 | Application shell, platform layer, compiled config | M00            | Alpha A     | Not started |
| M02 | Rope, transactions, anchors, headless core         | M01            | Alpha A     | Not started |
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

**Status:** Active
**Depends on:** —
**Next task:** M00.04

- [x] M00.01 Create repository/docs/agent workflow.
- [x] M00.02 Pin Odin, Sokol, shader tooling, and native dependencies.
- [x] M00.03 Build/run a window (Linux/X11 done; Windows deferred by decision).
- [ ] M00.04 Spike Unicode clipboard round-trip and large transfer.
- [ ] M00.05 Spike mixed-DPI and text-input/IME integration.
- [ ] M00.06 Spike native Wayland feasibility for chosen backend (deferred by decision; to be closed as documentation).
- [ ] M00.07 Spike PTY/ConPTY and asynchronous process output.
- [ ] M00.08 Prove minimal FUSE/WinFsp adapter deployment.
- [ ] M00.09 Record architecture decisions and compatibility inventory.

### Notes

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
- **Decision 2026-11-12 (owner).** Lock in on X11 for now; no Wayland and
  no Windows work this early. M00.06 will be closed as a documented
  decision; Windows halves of M00.03–M00.08 are deferred and must be
  recorded as such in the M00.09 compatibility inventory.
- M00 acceptance (SPECS.md): both Tier-1 OS build paths work; no unverified
  claim about Wayland/clipboard/IME is treated as solved; FS mount deployment
  risk is understood before M19.

---

## M01 — Application shell, platform layer, and compiled config

**Status:** Not started
**Depends on:** M00

- [ ] M01.01 Implement lifecycle and error-reporting infrastructure.
- [ ] M01.02 Add generated trusted configuration package.
- [ ] M01.03 Create logical/physical coordinate conversion.
- [ ] M01.04 Add native input normalization.
- [ ] M01.05 Add worker/result queues with bounded capacity.
- [ ] M01.06 Render basic column/tag/body rectangles.

## M02 — Rope, transactions, anchors, and headless core

**Status:** Not started
**Depends on:** M01

- [ ] M02.01 Implement immutable backing chunks.
- [ ] M02.02 Implement leaves, metrics, and range iteration.
- [ ] M02.03 Implement balancing and persistent root updates.
- [ ] M02.04 Implement coordinate conversion.
- [ ] M02.05 Implement transactions and revision tracking.
- [ ] M02.06 Implement anchor transformation.
- [ ] M02.07 Implement branching in-memory undo.
- [ ] M02.08 Add randomized differential tests and benchmarks.

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
