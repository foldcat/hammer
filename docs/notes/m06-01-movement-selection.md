# M06.01 — Movement and selection actions

**Status:** done as a backend-free core action layer. Linux unit validation and a
Windows-target type check passed. The product window does not yet consume these
actions, and product text drawing/typing remains unwired.

## Action API

`src/core/editing/editing.odin` adds `editing.Action`, initially supporting:

- `Move` with grapheme left/right, word left/right, line up/down, line start/end,
  and document start/end motions;
- `Select_All`;
- `selection_range` for a direction-independent half-open byte range.

`perform` and `move` operate on a caller-owned `txn.Selection`. They do not
change document text, history, or revision. Selection anchor/active direction
and affinity are preserved. An unextended left/right motion collapses an existing
selection to the corresponding edge without moving an extra grapheme or word;
an extended motion keeps the anchor fixed.

Vertical motion retains the preferred grapheme column across short lines.
Horizontal motion clears that preference. The stored column is a grapheme index,
not a pixel coordinate; renderer-aware pixel columns can be added when product
line layout is connected.

## Unicode and line behavior

The implementation uses the pinned Odin `core:unicode/utf8` grapheme iterator,
whose own upstream suite covers the Unicode grapheme-break cases. Combining
characters and ZWJ emoji therefore remain single cursor steps. Carets inside a
grapheme are rejected as `.Invalid_Input` rather than silently repaired.

Words are runs of Unicode letters/numbers or underscore, with all other
graphemes as separators. Word motion crosses line boundaries and preserves
grapheme boundaries. Line start/end excludes LF, CRLF, and lone-CR terminators.

Each motion reads at most one 64 KiB temporary copy per traversed line, allocated
with the caller's allocator and released before return. A longer line returns
`.Resource_Limit`; document-boundary and select-all actions do not copy text.
This is an explicit bounded-work limitation, not support for arbitrary huge-line
motion.

## Tests

`tests/unit/editing/editing_test.odin` adds eight allocator-tracked tests for:

- forward/backward combining-character and ZWJ-emoji motion across LF and CRLF;
- selection extension, reversal, collapse, direction-independent ranges, and
  affinity preservation;
- line/document boundaries and empty documents;
- preferred columns across short lines and combining graphemes;
- Unicode word motion, line crossing, and extended word selections;
- select-all and horizontal preference reset;
- out-of-range and split-grapheme rejection without selection/revision changes;
- the oversized-line resource limit.

`make.odin` includes `tests/unit/editing` in the core `test` target.

## Validation

```text
odin test tests/unit/editing -vet -collection:hammer=src
    -> 8/8 passed, allocator tracking clean
odin check src/core/editing -no-entry-point -vet
    -> passed
odin run make.odin -file -- test
    -> all 264 core unit tests passed
odin run make.odin -file -- text-test
    -> all 26 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- build
    -> Linux debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> ten-frame lifecycle smoke passed
odin check src/core/editing -no-entry-point -vet -target:windows_amd64
    -> Windows-target type check passed; no Windows runtime test
git diff --check
    -> no whitespace errors
```

## Limits and next task

- These actions are not yet bound to keyboard events or drawn in the product
  window. Actual typing is not implemented by this task.
- The 64 KiB per-line motion budget should be replaced by bounded local-window
  navigation if huge-line editing becomes an acceptance scenario.
- Vertical columns currently count graphemes, not shaped pixel positions.
- M06.02 should map normalized key-down events to these semantic actions,
  including Shift selection and Ctrl word/document modifiers, without inserting
  text from key commands.
