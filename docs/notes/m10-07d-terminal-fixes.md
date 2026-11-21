# M10.07d (slice 1) — Terminal fixes for full-screen apps

**Status:** done on Linux/X11. Testing htop and Neovim in the `Win` terminal
surfaced five defects; this slice fixes them at the console layer (unit-tested)
and the terminal wiring (compiled + smoke-tested). The fixes are the
terminal-emulation groundwork M10.07d depends on; the actual Neovim/htop runs
remain manual verification.

## Problems fixed

1. **Escape quit the editor** — the Escape-quit check in `main.event` ran after
   input dispatch unconditionally, so Escape never reached the child.
2. **Arrow keys did nothing in htop** — the grid always sent CSI arrows
   (`ESC [ A`); full-screen apps enable application cursor mode (DECCKM,
   `?1h`), which expects SS3 arrows (`ESC O A`).
3. **Empty CSI parameters were treated as 0** — `csi_param` returned 0 for a
   missing parameter, so `ESC [S`, `ESC [A`, etc. did nothing (a missing count
   is 1, not 0). This broke incremental scrolling/redraws.
4. **No scrolling region** — SU/SD/IL/DL scrolled the whole screen, ignoring
   DECSTBM (`CSI top;bottom r`), so full-screen apps' partial-region scrolls
   misaligned the screen.
5. **No mouse reporting** — the editor consumed the wheel/clicks for its own
   view scrolling; htop/Neovim never saw mouse events.

Also: Neovim's "B" glyph is a font-fallback artifact (a nerd-font icon not in
the terminal font), not a terminal-emulation defect; out of scope here.

## Changes

### Console (`src/core/console/ansi.odin`, `grid.odin`, `line.odin`)

- `Escape_Event` added to the parser event stream: single-character escapes
  (`ESC 7/8/D/E/M`) are now reported instead of dropped. ST (`ESC \`) is
  consumed correctly (a `st_pending` flag swallows the `\`).
- Grid tracks `application_cursor` (?1h/l), `mouse_reporting` (?1000h/l),
  `mouse_sgr` (?1006h/l), and a scrolling region (`scroll_top`/`scroll_bottom`,
  DECSTBM via `CSI r`), plus DECSC/DECRC cursor+style save/restore.
- `csi_count` makes a missing/0 count resolve to 1 for CUU/CUD/CUF/CUB/CNL/CPL/
  IL/DL/ICH/DCH/SU/SD.
- SU/SD/IL/DL and `grid_line_feed` now scroll within the region (and only a
  full-screen region feeds the scrollback). Region and cursor-key state reset on
  resize and alternate-screen switches.

### Terminal wiring (`src/terminal_ui.odin`, `src/main.odin`, `src/editor.odin`)

- `editor_terminal_write_key` forwards Escape (`0x1b`), and picks SS3 vs CSI for
  arrows/Home/End from `grid_application_cursor`.
- `main.event` no longer quits on Escape while a live terminal is active.
- `editor_terminal_mouse` forwards wheel (buttons 64/65) and clicks as SGR
  reports (`ESC [ < b ; col ; row M/m`) when ?1000+?1006 are on; otherwise the
  editor's own pointer handling proceeds.

## Tests

- `tests/unit/console/ansi_test.odin`: `test_parser_escape_and_csi_sequences`
  now asserts the `Escape_Event`; the ST terminator test stays 1 event.
- `tests/unit/console/grid_test.odin`: `test_grid_application_cursor_mode`,
  `test_grid_scroll_region`, `test_grid_empty_param_counts_one`,
  `test_grid_cursor_save_restore` pin the new behaviors.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src -> 92/92 passed
odin run make.odin -file -- test                        -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> clean
odin run make.odin -file -- terminal-test               -> 5/5 X11 terminal checks passed
git diff --check                                        -> clean
```

## Not validated and next task

Neovim/htop are not run headlessly here (no UI-driving harness for them), so the
fixes are validated by unit tests + the shell smoke test, not by driving a real
TUI. Mouse reporting only implements SGR (?1006); X10 and URXVT encodings, drag
tracking (?1002), and auto-wrap disabling (?7l) are not handled. Next: run htop
and Neovim in the terminal interactively to confirm, then finish M10.07d.
