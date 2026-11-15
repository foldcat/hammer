# M06.06 — Multiline indent/outdent transaction

**Status:** done as a backend-free editing action with transaction-backed tests.
Linux tests and product smoke passed; editing and keybind type-check for Windows.
The product window still has no editable document consumer, so visible desktop
indentation is not claimed.

## Editing behavior

`src/core/editing/indent.odin` adds `Indent_Settings`, `Indent_Direction`, and
`indent`. Callers supply the target buffer's effective tabs/spaces style and
width. Zero width selects four columns; widths above 32 and actions covering
more than 4096 lines return explicit errors. EditorConfig resolution itself
remains scheduled for M11.

For a nonempty selection, indentation covers every selected line except a final
line whose start is exactly the selection end. A collapsed Indent instead inserts
one unit at the caret. Tabs insert one tab; spaces insert the configured width.
Blank lines and CRLF documents use the same rope line coordinates.

Outdent removes one leading tab or up to one configured width of leading spaces
on each covered line, including for a collapsed caret. Existing indentation does
not need to match the configured insertion style. If no line has removable
indentation, the operation is a true no-op: text, revision, history, selection,
and preferred visual column remain unchanged.

Every effective action calls `txn.doc_apply` once with source `.Indent` and all
line operations in original-snapshot coordinates. Selection endpoints are
adjusted through those operations, direction and affinity are preserved, and the
post-edit selection is recorded for undo/redo. Operation storage is caller-
allocator owned and released on return; inserted unit bytes are borrowed only
during the synchronous apply and deep-copied by the transaction log.

## Keyboard resolution

Tab now always resolves to `keybind.Indent`, with or without a selection, so the
editing consumer can honor spaces at a collapsed caret. Shift+Tab remains
`keybind.Outdent`; auto-repeat remains rejected. The obsolete `has_selection`
parameter was removed from `resolve` and `resolve_event`. The keybind transaction
sequence now consumes both indentation actions through `editing.indent`.

## Tests

Six editing tests cover:

- multiline spaces, reverse selection direction, and one-step undo/redo;
- exclusion of a selection-ending line start and outdent round-trip;
- mixed tabs/spaces, short and long leading-space runs, and unindented lines;
- collapsed-caret insertion/outdent and unchanged no-op selection state;
- blank lines, CRLF, and reverse selection endpoint adjustment;
- invalid settings/carets and the covered-line resource limit.

Existing keybind tests now verify selection-independent Tab resolution, repeated
Tab suppression, and the resolved key-to-transaction path.

## Validation

```text
odin test tests/unit/editing -vet -collection:hammer=src
    -> 24/24 passed, allocator tracking clean
odin test tests/unit/keybind -vet -collection:hammer=src
    -> 12/12 passed, allocator tracking clean
odin check src/core/editing -no-entry-point -vet -target:windows_amd64
odin check src/core/keybind -no-entry-point -vet -target:windows_amd64
    -> both Windows-target type checks passed; no Windows runtime test
odin run make.odin -file -- test
    -> all 294 core unit tests passed
odin run make.odin -file -- build
    -> Linux debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> ten-frame lifecycle smoke passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- No real Windows runtime or product-window keyboard indentation was exercised.
- EditorConfig parsing/precedence and buffer overrides are not implemented here;
  the action accepts their resolved values without hardcoding a spaces policy.
- M06.07 should implement bounded IME preedit/commit handling without triggering
  key commands or losing the captured edit target.
