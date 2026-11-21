# M10.07d (slice 2) — DEC Special Graphics / charset designation

**Status:** done on Linux/X11 (unit-tested; interactive htop run is the
caller's manual check).

## Problem

Running htop in the `Win` terminal showed stray `B` (and `0`) glyphs scattered
through the output and misaligned borders. The "B" is not an invisible
formatting character: it is the designator of `ESC ( B` — the SCS sequence that
selects US ASCII (ncurses `rmacs`) — leaking into the transcript as text.

Full-screen apps draw borders with the DEC Special Graphics (ACS) character
set. ncurses emits `ESC ( 0` (`smacs`, enter line-drawing) around the border
rune set (`q x l m k j t u v w n` …) and `ESC ( B` (`rmacs`, back to ASCII)
after it. The ANSI parser treated `ESC (` as a single-character escape and
returned to Ground, so the following byte — `0` or `B` — was written as
printable text, and the border runes rendered as their literal ASCII letters
(`q`, `x`, …) instead of box-drawing glyphs.

## Fix

### Parser (`src/core/console/ansi.odin`)

- New `Parser_State.Charset` and a `charset_target` field: `ESC ( ) * + %`
  consumes one designator byte instead of echoing it.
- New `Charset_Event{target, designator}` in the event stream. A control or
  non-ASCII byte where the designator belongs cancels the designation and is
  reprocessed in Ground (same deterministic-cancel policy as CSI).

### Grid (`src/core/console/grid.odin`)

- `Grid.g0_charset` tracks the G0 set. `grid_charset` selects
  `Dec_Special_Graphics` for `ESC ( 0` and `Ascii` otherwise.
- `dec_special_graphics` maps the VT100/ACS runes to their Unicode
  box-drawing/typographic equivalents; `grid_write` translates through it when
  the G0 set is DEC Special Graphics.
- `grid_reflow_active` resets `g0_charset` to ASCII before re-wrapping so the
  verbatim reflow never re-translates literal `q`/`x`/… in command lines; the
  child's SIGWINCH redraw re-selects the set.

### Log stream (`src/core/console/line.odin`)

- Ignores `Charset_Event` (model-A log never echoes the designator).

## Tests

- `tests/unit/console/ansi_test.odin`: `test_parser_charset_designation`,
  `test_parser_charset_g1_and_utf8` (designator is consumed and reported, no
  text leak). `event_equal` handles the new variant.
- `tests/unit/console/grid_test.odin`: `test_grid_dec_special_graphics`
  (`ESC ( 0 lqk ESC ( B` → `┌─┐` etc.), `test_grid_charset_no_leak`.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src  -> 96/96 passed
odin run make.odin -file -- test                           -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin check src ... -target:windows_amd64 -define:SOKOL_USE_GL=true -> clean
git diff --check                                           -> clean
```

## Not validated / out of scope

- Interactive htop run (this is the user's manual check; no headless TUI
  harness here).
- G1/G2/G3 designation (`ESC ) * +`), shift-out/shift-in (SO/SI) switching,
  and `ESC # 8` (DECALN) are consumed but not applied; only G0 line drawing is
  translated. htop uses G0 via `smacs`/`rmacs`, so this covers it.
- The `_` designator maps to NO-BREAK SPACE (U+00A0) per the standard mapping;
  it is rarely emitted by ncurses ACS.
