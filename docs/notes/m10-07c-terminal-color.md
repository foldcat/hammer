# M10.07c — Terminal text & background color

**Status:** done on Linux/X11. The terminal grid's per-cell SGR colors are now
emitted as a parallel style-run list and rendered as foreground glyph colors and
background fills. The color mapping (basic/bright, 256-palette, true color) and
styled-transcript emission are unit-tested; the render path compiles clean on
Linux and the Windows cross-build and is exercised by the X11 terminal smoke
test with a colored command. Per-run attributes other than fg/bg (bold, dim,
italic, underline, blink, reverse, hidden, strikethrough) are parsed but not
rendered.

## Problem

M10.07b rendered the terminal as plain text: the grid carried an SGR `Style` on
every cell, but `grid_append_text` emitted only runes, so `ls --color`, a
colored prompt, or a colored `printf` all appeared in the default body color.
SPECS §12.7 requires styles to be stored separately from text and §12.6 lists
color support as a minimum.

## What was built

### Color resolution (`src/core/console/ansi.odin`)

- `ANSI_BASIC` — the standard xterm/VGA 16-color palette (indices 0..15).
- `color_rgb(Color) -> (rgb: [3]u8, has_color: bool)` resolves an SGR color to
  24-bit RGB: `.Basic` clamps to 0..15, `.Palette` uses the standard xterm
  256-color cube (16..231) and grayscale (232..255), `.RGB` passes through, and
  `.Default` reports `has_color = false` so the caller uses the terminal's
  default foreground/background.

### Styled transcript (`src/core/console/grid.odin`)

- `Style_Run { start, end, style }` — a byte-offset span of the emitted
  transcript with a uniform style (SPECS §12.7: styles stored separately from
  text).
- `grid_row_line_stride` now also builds coalesced style runs (`Line.runs`), so
  lines that scroll into the scrollback keep their colors.
- `grid_append_styled(g, out, runs)` is `grid_append_text` plus a parallel
  style-run list; `grid_append_line_styled` turns rune-length runs into
  byte-offset runs as UTF-8 is encoded. Newline bytes fall between runs (they
  are line separators, not styled cells).

### Terminal wiring (`src/terminal_ui.odin`)

- `Editor_Terminal.styles` (a `[dynamic]console.Style_Run`) is built alongside
  `render` in `editor_terminal_sync` via `grid_append_styled`, so the runs stay
  byte-aligned with the document (which is replaced wholesale from `render`).
- Color helpers `terminal_style_fg`/`terminal_style_bg` (with theme defaults),
  and binary-search lookups `terminal_run_at`/`terminal_first_run_before`.

### Rendering (`src/render.odin`, `src/text_render_native.odin`)

- `text_render_document`/`text_render_line`/`text_collect_glyphs` take a
  `styles: []console.Style_Run`; the terminal body passes its runs, tags pass
  `nil`. The glyph pass resolves each glyph's foreground from its source byte
  cluster (`line_start + glyph.cluster`); the background pass draws a fill quad
  for each run with a non-default background, mirroring the selection-highlight
  span logic. The terminal uses truncate wrap and no tabs, so source byte
  offsets map 1:1 to document offsets.

## Trade-offs and limitations

- Only foreground and background colors are rendered; bold/dim/italic/underline/
  blink/reverse/hidden/strikethrough are parsed into `Style` but have no visual
  effect yet.
- The ANSI 16-color palette is the fixed standard xterm set, not the editor's
  oxocarbon theme (the theme has no terminal-ANSI colors); a configurable
  terminal palette is a possible follow-up.
- Reverse video (SGR 7) is not applied.
- Style runs are rebuilt wholesale with the transcript on each grid update; a
  scrolled-up view's colors are only clamped, not precisely preserved through a
  screen rewrite (the same trade-off as the plain-text path).

## Tests

- `tests/unit/console/ansi_test.odin`: `test_color_rgb_resolution` pins the
  basic/bright, 256-cube/grayscale, and true-color mappings.
- `tests/unit/console/grid_test.odin`: `test_grid_append_styled` and
  `test_grid_append_styled_scrollback` pin that styled text (and scrolled-off
  lines) emit correct byte-offset style runs.
- `tests/integration/terminal/x11_harness.py`: added a `printf '\033[31m...'`
  command so the colored foreground/background path runs end to end.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src -> 88/88 passed
odin run make.odin -file -- test                        -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> clean
odin run make.odin -file -- terminal-test               -> 5/5 X11 terminal checks passed
git diff --check                                        -> clean
```

## Not validated and next task

The colored output is not pixel-asserted (the X11 harness checks the terminal
survives a colored command, not that a specific cell's color matches); color
mapping and style emission are unit-tested, the render path compiles on both
targets. Windows is still a ConPTY stub. Next: M10.07d — test the terminal on
complex CLI apps (Neovim, htop), which will exercise the alternate screen,
cursor addressing, and per-run colors together.
