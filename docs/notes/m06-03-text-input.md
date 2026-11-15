# M06.03 — Text input versus key commands

**Status:** done as a backend-free, transaction-backed typing path. Headless input
sequence validation and Windows-target type checks passed. The product window
still has no editable document consumer or product text renderer, so this task
does not claim visible desktop typing.

## Input separation

`keybind.resolve_event` now accepts normalized `input.Event` values:

- Printable `input.Text` becomes `editing.Insert_Text` with no command modifiers.
- Ctrl+Alt (AltGr), with optional Shift, also inserts committed text.
- Ctrl, Alt, Super, and Ctrl+Alt+Super text is suppressed so command keys cannot
  insert a second action.
- Control scalars in `Text` are ignored. Enter, keypad Enter, and Tab instead
  produce their edits on key down, preventing command/text duplication.
- Plain Backspace/Delete produce backward/forward grapheme deletion. Editing keys
  may auto-repeat; the M06.02 one-shot command policy remains unchanged.
- Tab with no selection inserts a tab. With a selection it resolves to the later
  indentation action; repeated indentation commands remain suppressed.

Key-up, pointer, and scroll events produce no keyboard editing action.

## Transaction-backed editing

`src/core/editing/text_input.odin` adds these variants to `editing.Action` and
`keybind.Action`:

- `Insert_Text` with a Unicode scalar and optional nonzero `grouping_key`;
- `Delete_Backward`;
- `Delete_Forward`.

Insertion replaces a nonempty selection in either direction or inserts at a
collapsed caret. Newline and tab use the same path. Every mutation calls
`txn.doc_apply` with `.Typing`, the current revision, and the post-edit selection.
The caller's selection changes only after a successful apply. Inserted UTF-8 is
borrowed only during the call; the transaction log owns its deep copy.

A shared nonzero insert group key joins consecutive commits into one undo step.
A zero key or a deletion breaks that run. This leaves run ownership with the view
rather than the stateless resolver.

Backspace/Delete removes an entire selection or the adjacent Unicode grapheme.
Combining characters and ZWJ emoji are never split. Document-edge deletion is a
true no-op: no revision or log entry. Invalid scalars, out-of-range selections,
and split-grapheme carets return `.Invalid_Input` without changing text,
selection, revision, or history. Existing 64 KiB line-budget errors also leave
state unchanged.

## Tests

Four editing tests cover Unicode and selection replacement, newline/tab,
consecutive-insert undo grouping, grapheme and selection deletion, document-edge
no-ops, invalid scalars, and split-caret rejection.

Five keybind tests cover normal and AltGr text, command-modified/control text,
special editing keys and repeats, ignored event kinds, and an end-to-end input
sequence. The sequence resolves text, Ctrl+C, Ctrl-modified text, Enter, AltGr,
Backspace, a control Text newline, and Tab, then verifies exact document bytes,
selection, one copy action, and five transaction nodes.

## Validation

```text
odin test tests/unit/editing -vet -collection:hammer=src
    -> 12/12 passed, allocator tracking clean
odin test tests/unit/keybind -vet -collection:hammer=src
    -> 12/12 passed, allocator tracking clean
odin check src/core/editing -no-entry-point -vet -target:windows_amd64
odin check src/core/keybind -no-entry-point -vet -target:windows_amd64
    -> both Windows-target type checks passed; no Windows runtime test
odin run make.odin -file -- test
    -> all 280 core unit tests passed
odin run make.odin -file -- text-test
    -> all 26 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- build
    -> Linux debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> ten-frame lifecycle smoke passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Product event dispatch, visible text/caret drawing, dirty tracking, and close
  review must be connected before real window typing can be claimed. No editable
  product buffer was added here, so the existing demo close behavior was not
  allowed to bypass unsaved-work review.
- IME preedit and multi-scalar commit handling remain M06.07.
- Clipboard actions remain semantic only until M06.04/M06.05.
- M06.04 should implement native clipboard services on both OS families with
  explicit ownership, bounded retries, and visible failures.
