# M10.07d (slice 4) — single terminal cursor

**Status:** done on Linux/X11 (compiled + X11 smoke test; interactive Neovim
visual confirmation is the caller's check).

## Problem

In the `Win` terminal, a full-screen app showed **two cursors**: the intended
block cursor, plus a stray thin vertical "line" cursor at the end of the
transcript. It became obvious when moving the cursor with arrow keys (the block
followed the app's cursor while the line stayed put).

The editor draws two things for a terminal body:

1. `render_terminal_cursor` — the real terminal block cursor, at the grid cursor
   position (Neovim positions it with CUP and toggles it with DECTCEM `?25h/l`;
   it does **not** use reverse video).
2. The editor's own text caret, drawn by `text_render_document` at
   `item.selection.active`. For a following terminal that selection sits at the
   end of the transcript (`editor_terminal_sync` pins it to `new_end`), so the
   caret rendered as a vertical line at the bottom — the second cursor.

## Fix (`src/render.odin`)

- `text_render_document` is now passed `text_active := body_active && !is_terminal`
  for terminal bodies, so the editor's text caret and IME preedit are suppressed
  while the terminal block cursor remains the only cursor. Selection highlighting
  (Ctrl+Shift+C copy) is unaffected — it is drawn independently of `active`.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin run make.odin -file -- terminal-test                  -> 5/5 X11 checks passed
git diff --check                                           -> clean
```

## Not validated / follow-up

- No pixel/visual assertion of the cursor (the X11 harness checks the terminal
  survives, not cursor geometry). Interactive Neovim/htop confirmation is the
  caller's check.
- The terminal cursor shape is always a block; DECSCUSR (`ESC [ 2 q` block,
  `ESC [ 6 q` bar, `ESC [ 4 q` underline) is parsed but not tracked, so insert/
  replace mode still shows a block. Left as a follow-up (the block was reported
  as "fine").
