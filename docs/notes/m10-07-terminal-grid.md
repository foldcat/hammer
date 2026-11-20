# M10.07 (slice 1) — Terminal grid, cursor addressing, and interactive input

**Status:** done on Linux/X11. The terminal window now renders through a real
terminal grid and runs its PTY slave in the cooked line discipline (echo on), so
the tty echoes each keystroke and the prompt and typed text appear immediately
instead of only after Enter. Resize (SIGWINCH) and the alternate screen remain
deferred (M10.07b).

## Problem

Two defects were reported against the M10.06 `Win` terminal:

1. **Crash** — running `exit` and pressing Enter a couple times aborted the
   editor with `Bounds check failed: 2 is out of range 0..<1` in
   `txn.doc_apply` (`src/core/txn/txn.odin:345`).
2. **Sluggish typing** — typed text did not appear until Enter. The terminal
   reused the model-A log stream, which holds a partial line until a newline,
   and the PTY ran in the `Sane` line discipline (echo off, canonical input),
   so nothing was echoed or displayed until the shell received a whole line.

## What was built

### Crash fix (`src/core/txn/txn.odin`)

`doc_collapse_history` clears the undo log and resets `current` to 0 after each
bounded output update, but it never reset `next_id`. After a terminal exited,
ordinary input fell through to text editing on the (now non-live) terminal
buffer; the first such edit became a root log entry with a large id, and the
second edit read `doc.log[parent - 1]` past the end of the log. The fix resets
`doc.next_id = 1` on collapse so ids stay dense again (`doc.log[i].id == i + 1`).

### Terminal grid (`src/core/console/grid.odin`, `grid_stream.odin`)

A model-B counterpart to `Stream`: a fixed rows×cols cell screen with a cursor
and a bounded scrollback, consuming the same ANSI event stream as `Line_Buffer`.
It implements text writing with auto-wrap, CR/LF/backspace/tab, cursor
addressing (`CUU/CUD/CUF/CUB/CNL/CPL/CHA/VPA/CUP`), erase-in-line/display,
insert/delete line and character, and scroll. `Grid_Stream` composes the UTF-8
decoder, ANSI parser, and grid. The grid is drained to text with
`grid_append_text` (scrollback + visible screen). Styles are carried on cells
but not emitted yet (SPECS §12.7).

### Terminal wiring (`src/terminal_ui.odin`, `src/core/process/pty*.odin`)

- Added `Termios_Mode.Cooked`: the line discipline a terminal emulator uses for
  a plain shell — cooked input (echo on, canonical input, control-character
  signals) and output post-processing on (ONLCR, so a child's `\n` still becomes
  `\r\n`). The tty echoes each keystroke back to the master; a line editor that
  needs raw input (readline) switches the slave to raw mode itself while it
  reads. `slave_set_terminal` implements it on Linux.
- `Editor_Terminal` now owns a `console.Grid_Stream` instead of the model-A
  `Output_Buffer`. `editor_poll_terminal` feeds PTY output into the grid and
  `editor_terminal_sync` replaces the buffer document with the grid transcript
  whenever the grid changes (collapsing history each time).

The original M10.06 terminal used `.Sane` (echo off), which is why typed text
never appeared: a plain `sh`/`dash` relies on the tty's echo, not readline. The
first M10.07 attempt used a raw-input line discipline, which also disabled echo
and made it worse; `.Cooked` is the correct default.

### Cursor position and auto-scroll (`src/core/console/grid.odin`, `terminal_ui.odin`)

- `grid_append_text` no longer appends a trailing `\n` after the current (last)
  screen row, so the transcript ends at the shell cursor's position on the last
  visible line instead of on a phantom blank line below it — the editor caret
  lands where you type.
- `editor_terminal_reveal_tail` scrolls the view so the last line stays visible
  at the bottom, but only when the view was already following the tail, so a
  user scrolled up to read earlier output is not yanked back down.

## Trade-offs and limitations

- The document is replaced wholesale on each grid update rather than diffed,
  so a scrolled-up view's selection is only clamped, not precisely preserved
  through a screen rewrite. Following the tail (the common case) is correct.
- Scrollback is bounded by line count (`DEFAULT_SCROLLBACK_LINES = 10000`),
  not bytes; each line is bounded by the column count.
- The alternate screen (`CSI ?1049h/l`) is not implemented: the ANSI parser
  drops private CSI markers, so full-screen programs (vim/less) scribble on the
  main screen. Resize and SIGWINCH are not wired. Per-run color rendering is
  still deferred.
- No explicit read-only guard: after `exit`, typing still inserts text into the
  (non-live) transcript — no longer crashes, but the buffer is not yet the
  "read-only transcript" the notes describe.
- There is no rendered terminal cursor: the shell's cursor is not drawn as a
  block/underline at its grid position, and the editor caret (which tracks the
  transcript end) can be moved only with the mouse, not the keyboard (keys are
  forwarded to the shell while live). A real terminal cursor plus scrollback
  navigation is deferred.

## Tests

- `tests/unit/console/grid_test.odin`: 14 grid tests covering basic lines,
  CR/backspace, cursor movement and absolute addressing, erase line/display,
  scroll + scrollback, auto-wrap, tab stops, and the full decode→parse→grid
  stream (including a split multi-byte sequence).
- `tests/unit/txn/txn_test.odin`: `test_collapse_history_dense_ids` reproduces
  the crash (verified to fail without the fix) and pins the dense-id invariant.
- `tests/unit/process/pty_test.odin`: `test_pty_cooked_mode_echoes_input` pins
  that the cooked line discipline echoes a write back to the master (the tty
  echo a plain shell relies on), verified by the echoed input appearing twice
  (once from the tty, once from the helper's reply).

## Validation

```text
odin test tests/unit/txn -vet -collection:hammer=src     -> 28/28 passed
odin test tests/unit/console -vet -collection:hammer=src -> 74/74 passed
odin run make.odin -file -- process-test                 -> 37/37 passed
odin run make.odin -file -- test                         -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin run make.odin -file -- terminal-test                -> 4/4 X11 terminal checks passed
git diff --check                                          -> clean
```

## Not validated and next task

Windows runtime is still a ConPTY stub. The tty echo is validated at the unit
level (`test_pty_cooked_mode_echoes_input`) and the terminal is exercised
end-to-end by the X11 harness, but no integration assertion reads the transcript
mid-line to confirm a keystroke appears before Enter. Next: M10.07b — terminal
resize (SIGWINCH), the alternate screen, a rendered terminal cursor, and
scrollback navigation, plus the read-only-transcript guard.
