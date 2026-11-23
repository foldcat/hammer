# M10.detour-3 — Explicit dirty-buffer discard and quit keys

**Status:** done on Linux/X11. Windows runtime was not exercised.

## Behavior

Dirty close and quit requests now enter the lifecycle's existing per-buffer
review flow. The pending buffer is activated and its entire contents selected
without changing text or undo history. A middle-clicked `Del` then explicitly
discards that exact buffer ID/generation/revision.

For a direct dirty `Del`, the first click selects the buffer and the second
closes its view. For quit, each explicit discard advances to the next dirty
buffer; the application exits only after every dirty buffer is saved or
discarded and running-job decisions are complete. Quit state is preserved while
waiting for jobs. Middle-clicks in window tags no longer cancel the pending
review before the command runs.

Escape no longer requests quit. It still cancels an in-progress Edit and is
forwarded to terminal applications. Ctrl+Q and the OS window-close button use
the same guarded quit path as before.

## Implementation

- `src/editor.odin` connects `Review_Unsaved` / `Discard_Current`, selects each
  pending buffer, advances multi-buffer quit review, and preserves decisions
  while jobs finish.
- `src/mouse_ui.odin` retains close review for middle-clicked window-tag
  commands so the second `Del` reaches the lifecycle.
- `src/main.odin` removes Escape-to-quit without changing terminal Escape or
  Edit cancellation.
- `docs/specs/10-input-clipboard.md` and `docs/specs/11-file-safety.md`
  describe the key and discard behavior.

## Tests

The typing X11 scenario proves Escape does not quit, the first `Del` highlights
the dirty buffer, and the second discards/closes only that view. The
compatibility scenario makes two buffers dirty, starts quit from an unrelated
window, verifies each is selected in turn, discards both explicitly, and checks
that neither unsaved edit reached disk. Integration cleanup now uses a shared
X11 Ctrl+Q helper instead of Escape.

Validation run:

```text
odin run make.odin -file -- test               -> all core unit tests passed
odin run make.odin -file -- typing-test        -> passed, including Escape and double-Del
odin run make.odin -file -- compatibility-test -> passed, including two-buffer discard/quit
odin run make.odin -file -- view-test          -> passed
odin run make.odin -file -- builtin-test       -> passed, including jobs + dirty quit
odin run make.odin -file -- look-test --no-config     -> passed
odin run make.odin -file -- layout-test --no-config   -> passed
odin run make.odin -file -- tag-test --no-config      -> passed
odin run make.odin -file -- terminal-test --no-config -> passed
odin run make.odin -file -- directory-test --no-config -> passed
odin run make.odin -file -- edit-test --no-config     -> passed
odin run make.odin -file -- wrap-test          -> passed
odin run make.odin -file -- scroll-test        -> passed
odin run make.odin -file -- autopair-test      -> passed
odin run make.odin -file -- ligature-test      -> passed
odin run make.odin -file -- emoji-test         -> passed
odin run make.odin -file -- unicode-test       -> passed
git diff --check                              -> clean
```

`mouse-test` remains blocked by an unrelated pre-existing expectation: it
expects unknown button-2 text not to execute, while the existing external
command router attempts `touch` and reports that the global tag has no body
window. This task did not change command routing. The look suite's first run
with the user's soft-wrap config clicked the wrong visual row; its isolated
`--no-config` run passed, including dirty quit protection.

## Next task

Return to M10.07d: exercise complex terminal applications such as Neovim and
htop and verify their advertised terminal interactions.
