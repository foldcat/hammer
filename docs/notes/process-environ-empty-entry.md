# Fix — empty environment entry crashes strict children (Neovim)

**Status:** done on Linux (unit-tested + reproduction confirmed); Windows
source-checked only.

## Problem

`nvim` (via oil.nvim) crashed inside the terminal with:

```text
nvim: .../funcs.c:1177: f_environ: Assertion `end != NULL' failed.
```

`f_environ` iterates the process `environ` and asserts every entry contains a
`=`. An **empty** entry (a bare NUL between two others) has no `=` and trips it.

Root cause is a chain of two things:

1. **Odin core bug** (`core/os/env_linux.odin`, the libc/CRT `_environ`): the
   copy loop is off by one and appends a trailing empty string, so
   `os.environ` returns N+1 entries (N real + one `""`).
2. **`build_exec` passed it through.** `process_linux.odin` copied every
   inherited entry into the exec envp verbatim, so the empty entry reached the
   child's `environ`.

Why it only appeared after M10.07e: the empty entry was always there, but
`sh`/`bash` drop it when re-exec'ing, while `zsh` propagates it. Switching the
terminal to the system shell (zsh) made `nvim` finally see it. `context.odin`
already filtered `entry == ""` for external commands; only the PTY/`build_exec`
path was missing the guard.

## Fix (`src/core/process/process_linux.odin`)

- `build_exec` now keeps only well-formed `KEY=VALUE` entries with a nonempty
  key (`strings.index_byte(entry, '=') > 0`) and sizes the envp accordingly,
  matching `validate_description`'s requirement for explicit environments.

## Tests

- `tests/unit/process/helper/envcheck_linux.odin` — a new helper command that
  walks the raw `posix.environ` array and reports `total=N malformed=M`.
- `tests/unit/process/pty_test.odin`:
  `test_pty_inherited_environment_has_no_malformed_entries` spawns the helper
  through `pty_spawn` (nil environment) and asserts `malformed=0`.

## Validation

```text
odin check src (linux) and (windows_amd64 + SOKOL_USE_GL)  -> clean
odin run make.odin -file -- process-test                    -> 38/38 passed
odin run make.odin -file -- test                            -> full core suite passed
odin run make.odin -file -- terminal-test                   -> 6/6 X11 checks passed
git diff --check                                            -> clean
```

Reproduction (independent C harness) confirmed: an empty env entry makes
`nvim -c 'lua print(vim.fn.len(vim.fn.environ()))'` assert-fail; filtering it
makes it print `OK 61`.

## Not validated / follow-up

- The Odin core `os.environ` off-by-one is not patched here (toolchain; a
  future Odin update could fix or keep it). The hammer-side filter is the
  durable guard. Worth reporting upstream.
- Windows ConPTY is still a stub; the Linux `build_exec` fix is the tested path.
