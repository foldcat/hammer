# M10.03 — CR/backspace/erase progress behavior

**Status:** done on Linux. The line buffer is pure Odin (no FFI, no platform
imports); the package and tests also `odin check` clean on the
`windows_amd64` target, but no Windows runtime result is claimed.

## What was built

`src/core/console/line.odin` (package `console`) adds a line-oriented progress
buffer that consumes the M10.02 event stream and assembles styled lines for
the log window (SPECS §12.5 model A).

- `Line_Buffer` holds the current line as a sequence of `Cell` (rune + style),
  plus a cursor and the current SGR style. It is a fixed-location, bounded
  value (see below).
- `line_buffer_feed(lb, events, &lines, &cleared)` applies the edits:
  - `Text` writes runes at the cursor using the current style, overwriting
    existing cells and appending past the end.
  - `Style` updates the current style.
  - `Control`: CR sets the cursor to 0; LF flushes the line; backspace moves
    the cursor back one; TAB is written literally.
  - `Csi`: `K` (erase in line) truncates to the cursor (0), deletes start to
    cursor (1), or clears the line (2); `J` (erase display) truncates to the
    cursor (0), or clears prior output (1/2, reported via `cleared`).
  - `Osc` is ignored (M10.04 owns the policy); other CSI (cursor addressing)
    is ignored (terminal grid is M10.07).
- `line_buffer_flush` emits a trailing partial line at end-of-stream (only if
  non-empty, so a `\r`-progress line that ends erased does not leave a blank
  line).
- Each completed `Line` owns `text []rune` and coalesced `runs []Run` (style
  spans in rune units); the caller frees them with `line_destroy`.

A `\r`-based progress bar therefore collapses to a single final line, and
styles are preserved through overwrites (overwriting a cell with new text
carries the new text's style; the untouched remainder keeps its original
style). The buffer is bounded at `max_cells` (default 64 KiB cells); a write
past the bound drops the overflow and counts it in `truncated`.

## Tests

`tests/unit/console/line_test.odin` (package `console_test`), 16 tests (40
total in the package):

- Basic line splitting, CR full/partial overwrite, backspace, erase-to-EOL /
  whole-line / start-to-cursor, styled runs, overwrite-preserves-style,
  erase-display clear signal, partial-line flush, multiline progress, blank
  lines, literal TAB, cell-budget truncation, and a self-overwriting progress
  bar.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src
    -> 40/40 tests passed, no leak/bad-free warnings
odin check src/core/console -vet -no-entry-point
odin check src/core/console -vet -no-entry-point -target:windows_amd64
odin check tests/unit/console -vet -no-entry-point -collection:hammer=src -target:windows_amd64
    -> package and tests source-check clean on Linux and windows_amd64
odin run make.odin -file -- test
    -> full core unit suite passed, including the console package
```

## Not validated and next task

Windows runtime behavior is not exercised (no Windows toolchain here). The
line buffer is not yet wired into `process.output_consume`; that integration,
plus interpreting `Osc_Event` payloads, is the next consumer.

Next: M10.04 — Implement hyperlink/control-sequence safety policy.
