# M10.02 — ANSI state machine and SGR styles

**Status:** done on Linux. The parser is pure Odin (no FFI, no platform
imports, no allocation on the data path); the package and tests also
`odin check` clean on the `windows_amd64` target, but no Windows runtime
result is claimed.

## What was built

`src/core/console/ansi.odin` (package `console`) adds a streaming ANSI/X3.64
state machine and the SGR style model, built on the M10.01 rune stream.

- `Style` is the resolved SGR rendering state: `fg`/`bg` `Color` plus
  `bold`/`dim`/`italic`/`underline`/`blink`/`reverse`/`hidden`/
  `strikethrough`. Its zero value is the SGR reset state.
- `Color` is a tagged struct (`kind` + `index`/`rgb`): terminal default, one
  of the 16 base colors (0..7 base, 8..15 bright), a 256-palette index, or
  24-bit true color. (A union was avoided because Odin union zero values are
  `nil`, not the first variant — `Color{kind = .Default}` is the unambiguous
  reset value.)
- `apply_sgr` interprets an SGR parameter list: reset (0), basic/bright colors
  (30-37/40-47/90-97/100-107), 256-palette (`38;5;n`/`48;5;n`), true color
  (`38;2;r;g;b`/`48;2;r;g;b`), and attribute on/off (1..9, 21..29). Unknown
  codes and malformed extended-color parameters are ignored; an empty list is
  reset. Palette/RGB channels clamp to 255.
- `Parser` is a fixed-location, allocation-free streaming state machine
  (`Ground`/`Escape`/`Csi`/`Osc`). `feed(p, input, out) -> (written, consumed)`
  emits a flat event stream; a buffer of `len(input)` events always consumes
  all input. Events:
  - `Text_Event` — a run of printable runes (borrows the feed input).
  - `Style_Event` — the resolved style after a `CSI ... m`.
  - `Csi_Event` — a non-SGR CSI sequence (final byte + params), for M10.03.
  - `Control_Event` — a C0/DEL/C1 control (other than ESC), for M10.03.
  - `Osc_Event` — an OSC payload (borrows parser storage), for M10.04.

Behavior: ESC starts a sequence; CSI collects parameters (digits, `;`/`:`
separators, private markers `< = > ?` ignored, intermediates ignored) and
dispatches on the final byte (`m` → SGR, else a `Csi_Event`). Single-character
escapes are ignored. OSC payloads (bounded at 1024 runes) are collected until
BEL or ST (ESC `\`) and reported, never executed. A control/ESC/non-ASCII byte
inside a CSI cancels it and reprocesses the byte in Ground; truncated trailing
sequences produce no events. Everything is deterministic and chunk-safe.

## Tests

`tests/unit/console/ansi_test.odin` (package `console_test`), 16 new tests
(24 total in the package):

- SGR reset, basic/bright, 256-palette, true color, attribute on/off, combined
  and unknown codes, empty-list reset, out-of-range clamping, malformed
  extended color.
- Parser: plain text runs, SGR + reset sequence, bright/true-color byte
  sequences, control characters (CR/LF/TAB/BEL), single-char escapes and
  non-SGR CSI (with params), OSC (BEL and ST terminators), CSI cancellation on
  an embedded control, partial consumption, trailing incomplete escape.
- Chunk-boundary invariance: 1000 pseudo-random byte streams decode to runes
  and are fed whole vs. at a random chunk size; the concatenated text and the
  non-text event sequence must agree exactly (text runs legitimately split at
  feed boundaries, so adjacent `Text_Event`s are coalesced for comparison).

The test helpers deep-copy the parser's borrowed `Text`/`Osc` rune slices
(`clone_event`/`delete_events`) so returned events own their data and the
memory tracker stays clean.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src
    -> 24/24 tests passed, no leak/bad-free warnings
odin check src/core/console -vet -no-entry-point
odin check src/core/console -vet -no-entry-point -target:windows_amd64
odin check tests/unit/console -vet -no-entry-point -collection:hammer=src -target:windows_amd64
    -> package and tests source-check clean on Linux and windows_amd64
odin run make.odin -file -- test
    -> full core unit suite passed, including the console package
```

## Not validated and next task

Windows runtime behavior is not exercised (no Windows toolchain here; the
parser has no platform code). The parser is not yet wired into
`process.output_consume`; CR/backspace/erase progress interpretation (M10.03)
and OSC/hyperlink safety (M10.04) are the next consumers of the `Control_Event`,
`Csi_Event`, and `Osc_Event` events.

Next: M10.03 — Implement CR/backspace/erase progress behavior.
