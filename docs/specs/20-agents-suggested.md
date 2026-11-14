# 20. Suggested `AGENTS.md`

```markdown
# Agent Operating Rules

## Product identity

This is an Acme reimagining in Odin and Sokol.

Preserve:

- Editable tags and text-oriented commands.
- Columns and windows.
- Select / execute / look.
- Original supported mouse chording.
- External programmability.
- Acme addressing and required Edit semantics.

Modernize:

- Native clipboard.
- Unicode/fonts/DPI.
- Async jobs.
- Safe save/recovery.
- Modern keyboard/touchpad access.
- Versioned local IPC and filesystem access.

Do not turn the project into a conventional IDE.

## Before changing code

1. Read NEXT.md.
2. Read the active milestone in `docs/roadmap/`.
3. Read relevant architecture and ADR documents.
4. Inspect existing implementation and tests.
5. Confirm prerequisites are complete.

## Work selection

Implement exactly one small, complete, testable task from the
active milestone.

Do not skip ahead unless a documented prerequisite requires it.

## Core invariants

- All buffer mutations go through transactions.
- The editor core has one mutation owner.
- Workers use immutable snapshots.
- Background results carry source revisions.
- Stale results never silently overwrite current state.
- Buffers and views are separate.
- Byte, scalar, grapheme, line, pixel, and terminal-cell positions
  are distinct types/concepts.
- No whole-buffer flattening on ordinary rendering/edit paths.
- No silent destructive encoding conversion.
- No close path bypasses dirty-buffer protection.
- No unlimited queues, output buffers, or caches.
- No native resource lifetime may be implicit.

## Platform policy

Do not claim cross-platform completion without validation.

Use platform adapters for:

- Clipboard.
- Processes/PTY.
- Fonts.
- DPI/IME.
- IPC.
- Filesystem mounting.

Do not use shell clipboard commands as the primary implementation.

## Safety policy

- Save failures leave buffers dirty.
- Disk conflicts require explicit handling.
- Recovery data is not pruned like ordinary history.
- IPC and filesystem writes use the same core actions.
- Output text is not automatically executed.
- Project-local Odin config is not automatically compiled.

## Validation

For every task:

- Add/update relevant tests.
- Run relevant tests.
- Run applicable builds/checks.
- Record exact commands and outcomes.
- State what was not tested.

Never claim tests passed unless they were run.

## Completion

Update:

- docs/roadmap/ (active milestone file)
- NEXT.md
- Relevant docs/ADRs
- Session summary

A stub is not a completed feature.

## End-of-session report

Report:

1. Task completed.
2. Files/modules changed.
3. User-visible behavior or invariant added.
4. Tests/builds run and results.
5. Known limitations/blockers.
6. Exact next task.
```
