# Modified Backspace detour

**Status:** done on Linux/X11; implemented in shared core code and cross-built for
Windows. This was a requested detour and does not replace the active M05.10 task.

## Behavior

`src/core/keybind/keybind.odin` handles Backspace modifiers before the ordinary
modifier rejection:

- Backspace, Ctrl+Backspace, Shift+Backspace, and Ctrl+Shift+Backspace all perform
  the existing grapheme-safe `Delete_Backward` action. Ctrl and Shift add no
  special behavior, including when a selection is active.
- Alt+Backspace performs `Delete_Word_Backward`. Shift may be held with Alt.
- Ctrl+Alt remains reserved for AltGr and Super-modified Backspace remains
  unbound, so neither accidentally deletes text.

`src/core/editing/text_input.odin` implements word deletion with the existing
`word_left` boundary. With a collapsed caret it deletes from that boundary to the
caret, including intervening separators and line breaks. With a nonempty selection
it deletes only the selection. The operation uses one `.Typing` transaction, moves
the caret to the range start, and is one undo step. Document start is a no-op;
invalid grapheme boundaries and oversized-line errors preserve document state.

## Coverage

Resolver tests cover plain/Ctrl/Shift/Ctrl+Shift/Alt/Alt+Shift Backspace and reject
AltGr/Super combinations. Editing tests cover ASCII, punctuation, a Unicode word
with a combining mark, line crossing, selection deletion, and undo.

The real X11 typing harness compares Ctrl, Shift, and Ctrl+Shift+Backspace against
literally typed `one tw`, and Alt+Backspace against `one `. Each case is undone back
to the initial document before the remaining typing/mouse/clipboard checks.

## Validation

```text
odin test tests/unit/keybind -vet -collection:hammer=src
    -> 13/13 passed, allocator tracking clean
odin test tests/unit/editing -vet -collection:hammer=src
    -> 27/27 passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 301 core unit tests passed
odin run make.odin -file -- typing-test --no-config
    -> all real X11 checks passed with isolated built-in configuration
odin run make.odin -file -- windows --no-config
    -> Windows product cross-build passed; Windows runtime was not exercised
git diff --check
    -> no whitespace errors
```
