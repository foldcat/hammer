# M06.12 — Newline indentation inheritance

**Status:** done on Linux/X11 with real product-window validation. The shared
editing implementation is platform-independent; Windows product behavior remains
unvalidated because the existing cross-build stops before source compilation.

## Behavior and ownership

`src/core/editing/text_input.odin` special-cases `Insert_Text` containing a
newline. After ordinary selection and grapheme-boundary validation, it reads the
line containing the first selected byte, scans its exact leading spaces and tabs,
and creates one bounded temporary buffer containing LF followed by that prefix.
The buffer is owned by the call and deleted on every return; `doc_apply` copies it
into the transaction log and chunk store. Line reads retain the existing
`MAX_LINE_BYTES` budget.

The newline and inherited indentation use one `Insert` for a collapsed caret or
one `Replace` for a selection. A reverse or multiline selection takes indentation
from its first selected line. The resulting caret follows the inserted prefix.
No keybinding, platform event, or editor grouping behavior changed.

## Regression coverage

`tests/unit/editing/text_input_test.odin` covers mixed tabs/spaces next to CRLF,
caret placement, one-operation transaction history, undo/redo, and reverse
multiline selection replacement. Existing coverage retains plain newline behavior
on unindented lines and grouped typing.

`tests/integration/typing/x11_harness.py` types a mixed-indentation line, presses
End to separate the Enter typing group, and presses Enter. It copies the complete
product document to a separate X11 clipboard reader to verify the exact bytes,
then verifies that one Ctrl+Z restores the source line before cleaning up the
source edit transactions.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin test tests/unit/editing -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 34 editing tests passed, allocator tracking clean
odin run make.odin -file -- typing-test
    -> Linux debug product build and all typing/mouse/clipboard checks passed
    -> exact inherited bytes and one-undo Enter behavior passed end to end
odin run make.odin -file -- test
    -> all 309 core unit tests passed, allocator tracking clean
odin run make.odin -file -- windows
    -> blocked before source compilation: Unknown flag: 'ignore-vs-search'
```

The pinned compiler has no `odin fmt` command and no `odinfmt` executable is
installed. Formatting was reviewed manually.

## Limits and next task

- Windows product input and Wayland remain unvalidated; the Windows cross-build
  blocker is unrelated to this editing change.
- No automatic indent widening after language-specific opening tokens was added;
  this task only inherits the source line's existing whitespace.
- Next is M06.13: implement and test the parenthesis/bracket/quote autopair policy.
