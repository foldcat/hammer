# M10.07d (slice 3) — background color erase (bce) + ECH

**Status:** done on Linux/X11 (unit-tested + X11 smoke test; interactive Neovim
visual confirmation is the caller's check).

## Problem

Two defects surfaced running Neovim in the `Win` terminal:

1. **Background color did not fill the empty parts of the screen.** Neovim
   draws each line as `SGR fg/bg` + text + `ESC [ K` (erase-to-end-of-line), and
   clears regions with `ESC [ J`. In a real terminal with `bce` (background
   color erase — xterm-256color advertises it), EL/ED fill the erased cells with
   the *current* background. The grid filled them with the default style, so the
   colored background stopped at the last written space.
2. **Old text was not cleared on redraw.** Neovim clears short regions with
   `ECH` (`ESC [ n X`, erase n characters) — e.g. `ESC [ 20 X` when the
   message/command line shrinks. The grid ignored CSI `X`, so the stale
   characters stayed put.

## Fix (`src/core/console/grid.odin`)

- Erase operations now fill with the current style (bce): EL (`K`), ED (`J`),
  ECH (`X`), and the blank cells inserted/deleted by ICH/DCH (`@`/`P`) and
  IL/DL (`L`/`M`) carry `g.style`; scrolling (`grid_clear_row`) keeps the
  default style so a newly-scrolled blank line has no background.
- `grid_erase_chars` implements CSI `X` (ECH): erase n cells in place without
  moving the cursor.
- `grid_row_last_col_stride` treats a cell with a non-default background as
  content, so trailing erased-but-colored cells are emitted as spaces (with
  their style runs) and the renderer's background pass fills the full line.

## Tests

- `tests/unit/console/grid_test.odin`: `test_grid_erase_characters` (ECH),
  `test_grid_erase_fills_background` (ED mode 2 under a set background),
  `test_grid_erase_line_fills_background` (EL under a set background — the
  Neovim redraw case).

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src  -> 99/99 passed
odin run make.odin -file -- test                           -> full core suite passed
odin check src (linux) and (windows_amd64 + SOKOL_USE_GL)  -> clean
odin run make.odin -file -- terminal-test                  -> 5/5 X11 checks passed
git diff --check                                           -> clean
```

## Not validated / known gaps

- Pixel-level background-fill assertion: the X11 harness only checks the
  terminal survives a colored command, not that a specific cell's background
  reaches full width (the grid-level unit tests cover the emission; the render
  path draws background quads for the emitted trailing spaces, same as for
  written spaces).
- `grid_reflow_active` (resize) re-writes snapshotted rows with the *current*
  style rather than their per-cell styles, so a live resize wipes per-cell
  colors until the child's SIGWINCH redraw re-establishes them. Pre-existing;
  not addressed here.
- DCS/PM/APC/SOS strings (`ESC P ... ESC \`, Neovim's startup DECRQSS query) are
  not consumed, so their payload can leak briefly; it is overwritten by the
  subsequent screen fill. Left as a follow-up.
