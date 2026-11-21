# M10.07e — System default shell for the terminal

**Status:** done on Linux/X11 (X11 terminal test asserts the shell; Windows
source-checked only).

## Problem

`Win` opened the terminal with a hard-coded fallback of `sh` (which resolves to
`/bin/sh`), so the user's login shell (`$SHELL`, the one set by `chsh`) and its
rc/aliases were ignored.

## Fix (`src/terminal_ui.odin`)

- New `editor_terminal_shell()` resolves the shell in priority order:
  1. `cfg.Shell` (explicit config override),
  2. `$SHELL` (the system default shell),
  3. `command.pipe_default_shell()` (`sh` on Unix, `cmd.exe` on Windows).
- `editor_command_win` uses it. The `$SHELL` lookup uses
  `os.lookup_env(..., context.temp_allocator)`; the result is cloned into the
  buffer's permanent storage by `editor_alloc_terminal_buffer`, so the
  frame-scratch borrow does not outlive the frame.

External-command routing (`>`, `<`, `|`) keeps `sh`/`cmd.exe` (M09.13 behavior,
unchanged); only the terminal's default changed.

## Validation

```text
odin check src (linux) and (windows_amd64 + SOKOL_USE_GL)  -> clean
odin run make.odin -file -- test                            -> full core suite passed
odin run make.odin -file -- terminal-test                   -> 6/6 X11 checks passed
                                                              (asserts shell="/usr/bin/zsh")
git diff --check                                            -> clean
```

`tests/integration/terminal/x11_harness.py` now also asserts that the
`terminal: opened ... shell=...` log records the resolved `$SHELL` (or `sh`
when unset).

## Not validated

- Windows execution (ConPTY is still a stub); the resolution is source-checked
  only. On Windows `$SHELL` is normally unset, so it falls back to `cmd.exe`.
- A `$SHELL` pointing at a nonexistent executable fails the spawn and surfaces
  the error rather than silently falling back; `chsh` validates the path, so
  this is the expected behavior.
