# M09.07 — Stale-target conflict behavior

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Selective automatic application

`src/core/process/selection.odin` now walks the current undo-history path from
the captured source revision. If every intervening edit is outside the original
selection, it transforms the range with anchors and applies the preserved stdout
against the current revision in one `.Command_Output` transaction. Insertions at
the range boundaries stay outside the replacement: the start uses left affinity
and the end uses right affinity.

An insertion inside a nonempty selection, an insertion at an empty selection, or
an overlapping delete/replace is a conflict. Replacement at an empty selection
is also a conflict when transforming the two boundaries would be ambiguous. A
source revision on an abandoned undo branch, stale buffer/request identity, or
an unavailable source window remains a conflict. Conflicts do not change the
document, selections, or undo history.

## Preserved output and explicit Apply

Conflicted stdout is still replayed into the bounded job-output window. Once
replay and error output drain, ownership of the complete `Selection_Pipe` moves
from the finished job to that output buffer. The process slot can therefore be
released without losing the fixed-capacity output or target metadata. Destroying
the output buffer releases an unapplied conflict; successful application releases
it immediately.

A conflicted job window offers `Del Apply`. `Apply` revalidates the source window,
buffer identity/generation, request ID, and current selection bounds. It replaces
the source view's **current** selection at the current revision, never the stale
range, so only text explicitly selected by the user is overwritten. The result is
one undo transaction. Failed, cancelled, and overflowing pipes do not offer
`Apply` because their captured stdout is not a successful complete result.

## Tests

The process suite now has 26 tests. New cases cover non-overlapping edits,
boundary insertions, empty-selection conflicts, abandoned history branches,
overlap rejection, explicit replacement, invalid explicit ranges, and one-step
undo. Allocator tracking is clean.

`tests/integration/builtins/x11_harness.py` starts a delayed purpose-built filter,
replaces the source selection before completion, and waits for the conflict. It
saves and checks the newer text, executes `Apply` in the real job window, saves
again, and checks that the preserved output was inserted at the current caret.

## Validation

```text
odin run make.odin -file -- process-test
    -> 26/26 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including 26 process tests
odin run make.odin -file -- builtin-test
    -> existing built-ins, flood output, Stop, and ordinary selection pipes passed
    -> conflict preservation and explicit Apply passed on Linux/X11
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product and process-test source checks passed
git diff --check
    -> passed
```

The pinned Odin toolchain does not provide an `odin fmt` command; no formatter
was run.

## Not validated and next task

Windows conflict behavior was not executed natively. General `>`, `<`, or `|`
command routing remains M09.10; the product launch used by the integration test
is still an explicit test hook.

Next: M09.08 should integrate running-job state into close/quit decisions without
weakening the existing dirty-buffer safety state machine.
