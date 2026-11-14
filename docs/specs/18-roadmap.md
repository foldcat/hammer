# 18. Implementation roadmap

Each milestone below is a **section of work**, not a single agent invocation.

The agent should implement one small, testable task from the active milestone per session.

Do not skip foundational milestones just because a later feature is easier to demo.

---

## M00 — Specification, feasibility spikes, and build baseline

### Deliverables

- Repository structure.
- Architecture documents.
- Acme compatibility matrix.
- Pinned toolchain/dependencies.
- Linux and Windows CI.
- Runnable Sokol sample.
- Native clipboard/DPI/IME feasibility notes.
- IPC and filesystem design decision.

### Tasks

```text
M00.01  Create repository/docs/agent workflow.
M00.02  Pin Odin, Sokol, shader tooling, and native dependencies.
M00.03  Build/run a window on Windows and Linux.
M00.04  Spike Unicode clipboard round-trip and large transfer.
M00.05  Spike mixed-DPI and text-input/IME integration.
M00.06  Spike native Wayland feasibility for chosen backend.
M00.07  Spike PTY/ConPTY and asynchronous process output.
M00.08  Prove minimal FUSE/WinFsp adapter deployment.
M00.09  Record architecture decisions and compatibility inventory.
```

### Acceptance

- Both Tier-1 OS build paths work.
- No unverified claim about Wayland, clipboard, or IME is treated as solved.
- A clear platform limitation is either resolved or explicitly blocks the affected release tier.
- FS mount deployment risk is understood before the final milestone.

---

## M01 — Application shell, platform layer, and compiled config

**Depends on:** M00

### Deliverables

- Application lifecycle.
- Logging.
- Platform service interfaces.
- Compiled configuration package.
- Basic renderer.
- Debug diagnostics window.

### Tasks

```text
M01.01  Implement lifecycle and error-reporting infrastructure.
M01.02  Add generated trusted configuration package.
M01.03  Create logical/physical coordinate conversion.
M01.04  Add native input normalization.
M01.05  Add worker/result queues with bounded capacity.
M01.06  Render basic column/tag/body rectangles.
```

### Acceptance

- Configuration edits visibly change colors/font-size settings after rebuild.
- Resize and scale changes do not crash.
- No dependency-specific code leaks into the core.

---

## M02 — Rope, transactions, anchors, and headless core

**Depends on:** M01

### Deliverables

- Persistent piece-rope.
- Text snapshots.
- Transactions.
- Buffer registry.
- Anchor transformations.
- Basic in-memory undo tree.

### Tasks

```text
M02.01  Implement immutable backing chunks.
M02.02  Implement leaves, metrics, and range iteration.
M02.03  Implement balancing and persistent root updates.
M02.04  Implement coordinate conversion.
M02.05  Implement transactions and revision tracking.
M02.06  Implement anchor transformation.
M02.07  Implement branching in-memory undo.
M02.08  Add randomized differential tests and benchmarks.
```

### Acceptance

- Randomized tests match the reference model.
- Snapshots remain valid after later edits.
- Large insert/delete operations do not flatten the entire buffer.
- Undo branches survive new edits after undo.

---

## M03 — File loading, codecs, safe save, and external changes

**Depends on:** M02

### Deliverables

- File-backed buffers.
- Chunked loading.
- Codec/EOL metadata.
- Safe save.
- File identity handling.
- External modification detection.

### Tasks

```text
M03.01  Implement canonical file identity.
M03.02  Implement background chunked loading.
M03.03  Implement UTF-8/BOM/newline policy.
M03.04  Implement explicit unsupported/invalid encoding behavior.
M03.05  Implement temporary-write/replace save.
M03.06  Implement disk-change conflict detection.
M03.07  Add failure-injection tests for save.
```

### Acceptance

- Untouched supported files round-trip correctly.
- Invalid bytes are not silently destroyed.
- Disk-full/permission/replace failure leaves the buffer dirty.
- External edits are not overwritten silently.

---

## M04 — Recovery journals, persistent history foundation, and shutdown guard

**Depends on:** M03

### Deliverables

- Recovery storage.
- Journal/checkpoint format.
- Crash replay.
- Persistent undo records.
- Safe close/quit state machine.

### Tasks

```text
M04.01  Implement versioned checksummed journal.
M04.02  Implement periodic checkpointing and rotation.
M04.03  Implement crash recovery discovery.
M04.04  Implement stale-session/lock detection.
M04.05  Persist undo transactions and branches.
M04.06  Implement dirty-buffer close/quit decisions.
M04.07  Implement save-failure exit blocking.
M04.08  Add kill-at-random-point recovery tests.
```

### Acceptance

- A torn last record does not invalidate prior records.
- Unsaved named and untitled buffers are recovered.
- No close path bypasses dirty checks.
- Recovery and history retention are separate.

---

## M05 — Unicode text renderer, fonts, and DPI

**Depends on:** M02; integrates M03/M04

### Deliverables

- FreeType/HarfBuzz integration.
- Unicode segmentation/bidi support.
- Font discovery/fallback.
- Glyph cache.
- Visible-line rendering.
- Correct hit testing.

### Tasks

```text
M05.01  Bind and pin font/shaping/Unicode libraries.
M05.02  Implement font discovery and role selection.
M05.03  Implement glyph atlas/cache lifecycle.
M05.04  Implement shaping and positioned runs.
M05.05  Implement selection/caret hit testing from shaped runs.
M05.06  Implement DPI change invalidation.
M05.07  Implement huge-line bounded rendering.
M05.08  Add mixed-script/DPI visual fixtures.
```

### Acceptance

- Combining characters and emoji do not produce invalid cursor positions.
- Selection geometry matches displayed text.
- Mixed-DPI movement preserves logical layout.
- Huge lines do not synchronously shape in full.

---

## M06 — Editing input, modern shortcuts, clipboard, and indentation

**Depends on:** M04, M05

### Deliverables

- Basic editor usable by keyboard.
- Native copy/cut/paste.
- Selection extension.
- Indent/outdent.
- IME support.

### Tasks

```text
M06.01  Implement movement and selection actions.
M06.02  Implement keyboard binding resolver.
M06.03  Implement text-input versus key-command separation.
M06.04  Implement native clipboard service on both OS families.
M06.05  Implement delayed-paste target validation.
M06.06  Implement multiline indent/outdent transaction.
M06.07  Implement IME preedit/commit handling.
M06.08  Add clipboard interoperability tests.
```

### Acceptance

- Copy/paste works with external applications.
- Large Unicode transfers work.
- Clipboard failure is visible, not replaced by stale content.
- AltGr and IME do not trigger erroneous shortcuts.
- Indentation is one undo step.

---

## M07 — Acme columns, windows, tags, mouse workflow, and lookup

**Depends on:** M06

### Deliverables

- Real Acme-style layout.
- Shared-buffer windows.
- Editable tags.
- Mouse state machine.
- Touchpad alternatives.
- Directory/lookup behavior.

### Tasks

```text
M07.01  Implement columns/window layout and dragging.
M07.02  Implement buffer/view separation in UI.
M07.03  Implement tag editing and generated command state.
M07.04  Implement original mouse actions/chords.
M07.05  Implement modifier-assisted gestures.
M07.06  Implement Look token expansion and file opening.
M07.07  Implement directory windows and error windows.
M07.08  Add compatibility scenarios for window behavior.
```

### Acceptance

- Multiple views share text but not selection/scroll.
- Middle/right actions match the compatibility specification.
- Touchpad users can execute/look without physical three-button hardware.
- Closing one view does not destroy a shared dirty buffer.

---

## M08 — Address language, internal commands, and Acme Edit

**Depends on:** M07

### Deliverables

- Command parser/registry.
- Address parser.
- Compatible regex behavior.
- `Edit` interpreter.
- Built-in command coverage.

### Tasks

```text
M08.01  Implement command dispatch and context.
M08.02  Implement line/character/range addresses.
M08.03  Implement compatible regex address semantics.
M08.04  Implement documented Edit command subset in dependency order.
M08.05  Complete required Edit coverage.
M08.06  Add cancellable snapshot-based execution for expensive edits.
M08.07  Implement atomic multi-buffer validation where needed.
M08.08  Add differential compatibility fixtures.
```

### Acceptance

- Do not mark complete with only search-and-replace implemented.
- `Edit` operations are undoable as coherent transactions.
- Long regex/edit operations are cancellable.
- Multi-buffer stale conflicts do not create partial unintended edits.

---

## M09 — Asynchronous external commands and selection pipes

**Depends on:** M08

### Deliverables

- Cross-platform job service.
- Output/error windows.
- Working-directory/environment context.
- Cancellation.
- Selection pipes.

### Tasks

```text
M09.01  Implement process spawning and handle ownership.
M09.02  Implement nonblocking stdin/stdout/stderr flow.
M09.03  Implement job lifecycle and Stop command.
M09.04  Implement contextual environment/cwd.
M09.05  Implement output-window batching/backpressure.
M09.06  Implement selection stdin/output replacement.
M09.07  Implement stale-target conflict behavior.
M09.08  Integrate running-job quit decisions.
```

### Acceptance

- Long commands do not freeze editing.
- Cancellation cleans up child processes appropriately.
- Output floods remain bounded.
- A late pipe result cannot overwrite newer selection edits.

---

## M10 — Unicode ANSI console and PTY/ConPTY terminal mode

**Depends on:** M09

### Deliverables

- Streaming console decoder.
- Styled log output.
- Progress handling.
- Optional terminal view.
- Terminal resize/input integration.

### Tasks

```text
M10.01  Implement chunk-safe UTF-8 decoder.
M10.02  Implement ANSI state machine and SGR styles.
M10.03  Implement CR/backspace/erase progress behavior.
M10.04  Implement hyperlink/control-sequence safety policy.
M10.05  Implement PTY/ConPTY process mode.
M10.06  Integrate a tested terminal-emulation layer.
M10.07  Implement resize, alternate screen, and raw input.
M10.08  Test advertised terminal capabilities.
```

### Acceptance

- Split escape sequences decode correctly.
- Colored compiler output is readable and selectable.
- Terminal cell positions are not confused with editor byte offsets.
- Do not advertise xterm-level compatibility if only ANSI colors are implemented.

---

## M11 — EditorConfig and polished compiled-config workflow

**Depends on:** M06, M09

### Deliverables

- EditorConfig resolver/cache.
- Effective buffer settings.
- Save-time transformations.
- `ConfigBuild` flow.
- Safe application handoff.

### Tasks

```text
M11.01  Implement tested EditorConfig resolution.
M11.02  Apply indentation settings.
M11.03  Apply explicit EOL/charset save policies.
M11.04  Implement undoable trailing-space/final-newline formatting.
M11.05  Add asynchronous config-build command.
M11.06  Add staged restart/handoff.
M11.07  Add config validation/diagnostics.
```

### Acceptance

- Official/compatible EditorConfig fixtures pass.
- Failed compilation leaves the running editor unchanged.
- Project-local executable configuration is not compiled automatically.
- Restart preserves unsaved work and layout.

---

## M12 — Incremental Tree-sitter highlighting

**Depends on:** M02, M05, M11

### Deliverables

- Parser worker integration.
- Rope input callbacks.
- Incremental tree edits.
- Highlight queries.
- Large-file budget.

### Tasks

```text
M12.01  Pin runtime/bindings/initial grammars.
M12.02  Implement rope-backed TSInput.
M12.03  Convert transactions to parser edits.
M12.04  Implement worker-owned incremental trees.
M12.05  Implement revisioned highlight publication.
M12.06  Implement invalidation and query scope expansion.
M12.07  Add initial language set and plain-text fallback.
M12.08  Add parser budget/cancellation tests.
```

### Acceptance

- Typing does not wait for parsing.
- Stale highlights are discarded or clearly bounded.
- Selection remains readable over all syntax colors.
- Parser failure never prevents editing.

---

## M13 — Lightweight buffer completion

**Depends on:** M06, M12

### Deliverables

- Incremental word index.
- Completion ranking.
- Popup.
- Transactional acceptance.

### Tasks

```text
M13.01  Implement word-boundary token extraction.
M13.02  Implement incremental count/index updates.
M13.03  Implement ranking and bounded result count.
M13.04  Implement popup input/focus rules.
M13.05  Implement completion transaction.
M13.06  Implement large-file limits.
```

### Acceptance

- No mandatory semantic server.
- Completion acceptance is one undo operation.
- Tab indentation still works.
- IME composition is not interrupted.

---

## M14 — Interactive persistent undo tree

**Depends on:** M04, M07

### Deliverables

- `History` window.
- Branch visualization.
- Node navigation.
- Persistent archive validation.
- Retention management.

### Tasks

```text
M14.01  Expose history model to a special buffer/view.
M14.02  Render textual/visual branch tree.
M14.03  Implement jump/preview actions.
M14.04  Persist labels/checkpoints/branch selection.
M14.05  Validate history against reopened disk content.
M14.06  Implement orphaned-history handling.
M14.07  Implement safe budget/pruning policy.
```

### Acceptance

- Branches survive restart.
- History is not replayed onto unrelated file content.
- Pruning never destroys the current recovery path.
- Jumping branches preserves other branches.

---

## M15 — Fuzzy finder and project indexing

**Depends on:** M07, M09

### Deliverables

- Project path index.
- File/buffer/command finder.
- Preview.
- Ignore rules.
- Async cancellation.

### Tasks

```text
M15.01  Implement bounded project traversal.
M15.02  Implement ignore and symlink policy.
M15.03  Implement fuzzy ranking/highlight spans.
M15.04  Implement finder overlay/special window.
M15.05  Implement preview and open actions.
M15.06  Implement incremental refresh/cancellation.
M15.07  Benchmark large-project queries.
```

### Acceptance

- A 100k-path project does not rescan per key.
- Unicode paths work.
- Stale query results do not replace current results.
- Symlink cycles cannot hang indexing.

---

## M16 — Persistent per-project layout and session restoration

**Depends on:** M04, M07, M15

### Deliverables

- Versioned session format.
- Layout autosave.
- Scratch references.
- Restore/relocation logic.

### Tasks

```text
M16.01  Serialize columns/window order and ratios.
M16.02  Serialize view anchors and tags.
M16.03  Persist scratch/recovery references.
M16.04  Implement debounced safe writes.
M16.05  Implement restore with missing-file states.
M16.06  Implement schema migration/fallback.
M16.07  Implement explicit project relocation.
```

### Acceptance

- Layout restores across DPI changes.
- Corrupt layout data does not lose buffer recovery data.
- Tags are restored without auto-executing commands.
- Previously running jobs are not silently restarted.

---

## M17 — Lightweight Git state and change navigation

**Depends on:** M09, M15, M16

### Deliverables

- Branch/status.
- Changed-file markers.
- Buffer line-change indicators.
- Next/previous change.

### Tasks

```text
M17.01  Detect repository/worktree context.
M17.02  Parse machine-readable status safely.
M17.03  Compute file/index/HEAD baseline metadata.
M17.04  Compute unsaved-buffer change hunks.
M17.05  Render compact markers and tag status.
M17.06  Implement hunk navigation.
M17.07  Add debounce/cancellation and non-Git fallback.
```

### Acceptance

- Paths containing whitespace/newlines are handled correctly.
- Git work is off the UI thread.
- Baseline distinctions are correct.
- The editor remains fully usable without Git installed.

---

## M18 — Modern local IPC and command-line client

**Depends on:** M08, M09, M16

### Deliverables

- Socket/named-pipe server.
- Versioned protocol.
- `acmectl`.
- Revisioned edits.
- Event subscriptions/interception.

### Tasks

```text
M18.01  Implement framing/version negotiation.
M18.02  Implement local authorization/ACLs.
M18.03  Implement read/list/create operations.
M18.04  Implement revisioned mutation operations.
M18.05  Implement chunked text transfer.
M18.06  Implement event stream/sequence handling.
M18.07  Implement interception/reinjection lease state.
M18.08  Implement acmectl and script examples.
M18.09  Add disconnect/abuse/conflict tests.
```

### Acceptance

- IPC edits go through ordinary transactions and undo.
- Stale writes return explicit conflicts.
- Disconnects do not leave input blocked.
- No remote interface is enabled by default.

---

## M19 — Filesystem projection and live filesystem adapters

**Depends on:** M18

### Deliverables

- Driverless state projection.
- Request/reply mailbox.
- Event segments.
- FUSE adapter.
- WinFsp adapter.
- Acme-style live entries.

### Tasks

```text
M19.01  Implement revisioned ordinary-file projections.
M19.02  Implement atomic request mailbox and replies.
M19.03  Implement event retention/gap reporting.
M19.04  Implement Unix mounted adapter.
M19.05  Implement Windows mounted adapter.
M19.06  Implement per-open addr/data/event semantics.
M19.07  Implement safe cancellation/unmount/shutdown.
M19.08  Add shell-based read/write/execute examples.
M19.09  Add filesystem compatibility tests.
```

### Acceptance

- State is inspectable through normal filesystem tools.
- Projection revisions are explicit.
- Full live semantics work through the mounted adapters.
- Mounted reads/writes do not duplicate editor logic.
- No whole-buffer export happens on every keystroke.
- Filesystem-driven close/save obeys ordinary safety rules.

---

## M20 — Compatibility completion, hardening, packaging, release

**Depends on:** all required milestones

### Deliverables

- Completed compatibility matrix.
- Performance report.
- Platform support report.
- Installers/packages.
- Recovery documentation.
- Security review.
- Release checklist.

### Tasks

```text
M20.01  Close required Acme compatibility gaps.
M20.02  Run full cross-platform integration matrix.
M20.03  Run performance and large-file benchmarks.
M20.04  Run crash/disk-error/clipboard stress tests.
M20.05  Audit resource ownership and cancellation.
M20.06  Audit dependency licenses and packaging.
M20.07  Package runtime/native FS dependencies.
M20.08  Document limitations and migration.
M20.09  Prepare release candidate and soak testing.
```

### Acceptance

No required feature is declared finished solely because:

- A demo exists.
- The happy path works.
- One OS passes.
- A stub interface has been created.
- The agent believes it “should work.”
