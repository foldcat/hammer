# M10.04 — Hyperlink/control-sequence safety policy

**Status:** done on Linux. The OSC parser and hyperlink tracking are pure Odin
(no FFI, no platform imports); the package and tests also `odin check` clean on
the `windows_amd64` target, but no Windows runtime result is claimed.

## What was built

`src/core/console/osc.odin` (package `console`) adds OSC classification and the
safety policy (SPECS §12.6):

- `osc_parse(payload) -> Osc` classifies an OSC payload by its leading decimal
  command number. `Osc` is a union: `Osc_Title` (0/1/2), `Osc_Hyperlink` (8),
  `Osc_Clipboard` (52), `Osc_Cwd` (7), and `Osc_Ignored` (everything else,
  including malformed input). The result borrows the payload and allocation is
  none.
- `Control_Policy` is the gate; its zero value denies everything with a side
  effect (`allow_clipboard = false`). Hyperlinks and title/cwd strings are
  inert data: classified and reported, never executed. OSC 8's URI is
  everything after the second `;` (the `id=...` params field is skipped); OSC
  52 splits `selection;data`.

`src/core/console/line.odin` now tracks hyperlinks through the line buffer:

- `Cell` gains a `link` index; `Line_Buffer` keeps a per-line URI table and the
  active link. `handle_osc` opens a link (copying the URI) or closes it (empty
  URI); every other OSC command is inert.
- `Line` gains `links: []Link` (rune range + owned URI), coalesced in
  `build_line`. Links are line-scoped: one left open at a line feed is closed
  there. `line_destroy` frees them.

### Fix: OSC payload lifetime in the M10.02 parser

Testing multiple hyperlinks on one line exposed a bug: the parser emitted every
`Osc_Event.payload` as a slice of its single reusable `osc` buffer, so a second
OSC sequence in the same feed overwrote the first one's payload. The parser now
copies each OSC payload into owned storage (`Parser.allocator`, released at the
next feed or by `parser_destroy`) and requires `parser_init`/`parser_destroy`.
`Text_Event.runes` still borrows the input slice.

## Tests

`tests/unit/console/osc_test.odin` (package `console_test`), 11 tests (52 total
in the package):

- OSC parsing: title/cwd, hyperlink (empty URI closes, params skipped), 52
  clipboard, ignored/malformed cases.
- `Control_Policy` default denies clipboard.
- Line-buffer hyperlinks: single, with surrounding text, multiple distinct
  links on one line, link closed at end-of-line, clipboard/title inert,
  hyperlink combined with SGR style.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src
    -> 52/52 tests passed, no leak/bad-free warnings
odin check src/core/console -vet -no-entry-point
odin check src/core/console -vet -no-entry-point -target:windows_amd64
odin check tests/unit/console -vet -no-entry-point -collection:hammer=src -target:windows_amd64
    -> package and tests source-check clean on Linux and windows_amd64
odin run make.odin -file -- test
    -> full core unit suite passed, including the console package
```

## Not validated and next task

Windows runtime behavior is not exercised (no Windows toolchain here). The line
buffer and OSC policy are not yet wired into `process.output_consume`; the
clipboard-write path that `Control_Policy` gates is the platform/UI layer
(M10.06), which will check `allow_clipboard` before touching the clipboard.

Next: M10.05 — Implement PTY/ConPTY process mode.
