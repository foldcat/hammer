# M10.06 (slice 2) — `Win` terminal window

**Status:** done on Linux/X11. The terminal window reuses the PTY process mode
(M10.05) and the console stream/output buffer (slice 1). The product and tests
`odin check` clean on `windows_amd64`, but ConPTY is still a `.Unsupported` stub
and no Windows runtime result is claimed.

## What was built

`src/terminal_ui.odin` (package main) adds the `Win` command and the terminal
window — SPECS §12.5 model B, first cut:

- `Editor_Terminal` owns a `process.Pty`, a `process.Output_Buffer` (the same
  bounded, ANSI-decoding, scrollback-trimming output path as job windows), a
  fixed read buffer, and lifecycle flags. It lives inside `Editor_Buffer` (fixed
  location; `Editor_Buffer` is never copied, so the non-copyable `Pty` is safe).
- `editor_command_win` runs the configured shell (`cfg.Shell`, else
  `pipe_default_shell`) on a PTY and opens it as a `.Terminal` buffer. A failed
  PTY spawn or buffer allocation stops/reaps/destroys the PTY before returning.
- Output: `editor_poll_terminals` (called once per frame from `main.frame`)
  drains the PTY master into the output buffer and reaps the child without
  blocking. Once the child is reaped and the master reaches end-of-stream, it
  flushes the trailing partial line, appends an `[exited: N]` marker, and
  destroys the PTY. The buffer stays open as a read-only transcript.
- Input: `editor_terminal_input` (called from `editor_consume_input` after
  pointer/chord handling, before `keybind.resolve_event`) forwards body input of
  a live terminal to the PTY: `Text`/`Commit_Text` as UTF-8, `Enter` as `\r`,
  `Backspace` as DEL, `Tab` as `\t`, arrow/Home/End/Delete as ANSI escapes, and
  Ctrl+letter as the control byte (so Ctrl+C/D/W reach the shell).
- Cleanup: `editor_destroy_buffer` stops (SIGKILL, process group), reaps, and
  destroys the PTY when a terminal window closes (`Del`/shutdown).

This is a line-oriented terminal: the console stream collapses CR/backspace/
erase progress and emits whole lines, so a shell prompt without a trailing
newline is held until the next newline or exit. Cursor addressing, the
alternate screen, resize (SIGWINCH), and raw input are M10.07.

## Trade-offs and limitations

- Escape still quits the editor (the Escape-quit check in `main.event` runs
  after input dispatch and is not overridden), so Escape is not forwarded to the
  shell. Ctrl+W and other editor shortcuts are forwarded to the shell while a
  terminal is focused, so the window is closed via `Del`, not Ctrl+W.
- `pty_write` is best-effort: a partial nonblocking write is logged and dropped
  rather than retried (interactive input is tiny; backpressure is not expected).
- Closing a live terminal blocks briefly in `pty_wait` after a forced SIGKILL
  (the child is a session leader; the whole group is signaled).

## Tests

`tests/integration/terminal/x11_harness.py` (new `terminal-test` target in
`make.odin`) runs the real product under Xvfb/X11: it opens `Win`, types
`echo terminal-ok`, then `exit`, and asserts the `terminal: opened` /
`terminal: exited` log sequence and that the terminal buffer received nonempty
output. This exercises the PTY spawn, input forwarding, output decode, and reap
end to end.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol   -> passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> passed
odin run make.odin -file -- test                                -> full core suite passed
odin run make.odin -file -- builtin-test                        -> 22 scenarios passed
odin run make.odin -file -- terminal-test                       -> 4/4 terminal checks passed
git diff --check                                                 -> passed
```

## Not validated and next task

Windows runtime (ConPTY) is unimplemented and unclaimed. The terminal is
line-oriented: no cursor addressing, alternate screen, resize, or raw input —
that is M10.07. The OSC clipboard policy (M10.04) is still not wired to the
platform clipboard layer. Per-run ANSI color rendering remains deferred
(SPECS §12.7).
