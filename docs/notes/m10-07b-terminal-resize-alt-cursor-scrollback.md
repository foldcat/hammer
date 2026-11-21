# M10.07b — Terminal resize, alternate screen, rendered cursor, and scrollback navigation

**Status:** done on Linux/X11. The terminal grid now resizes with the window
(SIGWINCH), supports the alternate screen (`CSI ?1049h/l`), renders a block
cursor at the shell's grid position, navigates scrollback from the keyboard
while live, and copies the selection with Ctrl+Shift+C. Windows runtime remains
a ConPTY stub (unclaimed), consistent with the rest of M10.

## Problem

M10.07a left four gaps on the terminal window (plus the copy binding named in
the roadmap):

1. The grid is fixed at spawn size (`TERMINAL_COLS×TERMINAL_ROWS`); resizing the
   window never reflowed the grid or told the child (no SIGWINCH).
2. The ANSI parser dropped the DEC private marker (`?`), so full-screen programs
   (vim/less) using `CSI ?1049h/l` scribbled on the main screen instead of
   entering the alternate screen.
3. There was no rendered terminal cursor — the shell's cursor was not drawn at
   its grid position, only the editor caret at the transcript end.
4. Scrollback could not be navigated from the keyboard while the shell was live
   (keys are forwarded to the PTY).

## What was built

### ANSI parser private marker (`src/core/console/ansi.odin`)

`Csi_Event` gains a `private: bool` and the parser now records `?` during CSI
parameter accumulation (the `<`, `=`, `>` markers stay ignored). `CSI ?1049h/l`
and `CSI ?25h/l` reach the grid with `private = true`; plain `CSI ... h/l` does
not. The field is included in `event_equal` so chunk-invariance tests compare it.

### Grid alternate screen and cursor visibility (`src/core/console/grid.odin`)

- `?1049h` saves the main screen (cells, scrollback, cursor, wrap flag) and
  presents a cleared screen with the cursor home; `?1049l` discards the
  alternate screen and restores the main screen. The save is a buffer-header
  swap — no deep copy, no double free (`grid_destroy` frees both active and
  saved buffers).
- `?25h/l` (DECTCEM) toggles `cursor_visible`, exposed via
  `grid_cursor_visible`.

### Grid resize (`src/core/console/grid.odin`)

`grid_resize(rows, cols)` reflows the visible screen at the new width and
preserves scrollback. Each source row is re-emitted as a hard line (the grid
does not track wrap flags, so soft-wrapped runs are not re-joined). The cursor
is restored clamped to the new bounds; the child's SIGWINCH redraw repositions
it authoritatively. When the alternate screen is active, the parked main screen
is reflowed too (via `grid_swap_active_and_saved`) so it stays well-formed at
the new size on exit. Snapshot helpers (`grid_row_line_stride`,
`grid_last_non_empty_row_stride`, `cell_at_stride`) read a screen at its old
row/column stride before `g.cols` changes.

### Terminal wiring (`src/terminal_ui.odin`, `src/mouse_ui.odin`, `src/render.odin`)

- `editor_terminal_resize_if_needed` runs once per frame for live terminals: it
  derives rows/cols from the window's text area and the body font
  (`text_measure_advance("M")`, line height), then calls `grid_resize` and
  `pty_resize` (SIGWINCH) when the size changed. Terminal windows now open with
  `.Truncate` wrap and no line numbers, so grid cells map 1:1 to document lines.
- `Editor_Terminal.following` replaces the fragile "selection == end" tail
  detection. `editor_terminal_sync` reveals the tail only while following;
  scrolling away sets it false.
- `editor_terminal_scrollback` (Shift+PageUp/PageDown) scrolls the live view by
  one screen and updates the follow flag; the wheel path calls
  `editor_terminal_sync_follow` for the same effect. Ctrl+Shift+C copies the
  terminal's selection instead of sending `\x03` to the shell.
- `render_terminal_cursor` draws a block cursor at the grid cursor position,
  mapping screen (row, col) to a pixel rect from the monospace cell size
  (`scrollback_len + row` → document line). It is drawn after the text pass
  from a dedicated `render_cursor_buffer` (a transient buffer cannot be
  rewritten once bound), so the block sits on top of the cell.

## Trade-offs and limitations

- The block cursor is a solid fill in the caret color, not an inverted cell;
  the character under it is hidden rather than re-rendered in the background
  color. Per-run color rendering (M10.07c) is still deferred, so the grid's
  cell styles are not emitted.
- Resize reflows by hard lines; soft-wrapped runs are not re-joined, and when
  the screen grows, blank rows are left at the bottom (scrollback lines are not
  pulled back in). The shell's SIGWINCH redraw repaints authoritatively.
- Scrollback navigation scrolls by one screen but is capped by the shared
  `MAX_SCROLL_ROWS_PER_EVENT` (64) bound, so a very tall terminal scrolls at
  most 64 rows per keypress.
- Only `?1049h/l` (the combined save+clear alternate) is handled; the separate
  `?47`/`?1047` forms are not.

## Tests

- `tests/unit/console/ansi_test.odin`: `test_parser_dec_private_csi` pins that
  `?1049h`/`?25l` carry the private marker and plain CSI does not; `event_equal`
  now compares `private`.
- `tests/unit/console/grid_test.odin`: alternate-screen enter/exit and
  scrollback preservation, resize rewrap, shrink-into-scrollback, cursor
  visibility/position, and resize-while-in-alternate-screen (the parked main
  screen is reflowed, not restored at a stale size).
- `tests/integration/terminal/x11_harness.py`: added a check that the terminal
  logs `terminal: resize` after opening, proving the SIGWINCH path runs end to
  end.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src -> 85/85 passed
odin run make.odin -file -- test                        -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> clean
odin run make.odin -file -- terminal-test               -> 5/5 X11 terminal checks passed
git diff --check                                        -> clean
```

## Not validated and next task

The rendered cursor and scrollback navigation are exercised only by the X11
smoke test (open/resize/type/exit); no integration assertion reads the cursor
pixels or drives Shift+PageUp. Windows is still a ConPTY stub. Next:
M10.07c — terminal text & background color (emit the grid's per-cell SGR styles
to the transcript, SPECS §12.7).
