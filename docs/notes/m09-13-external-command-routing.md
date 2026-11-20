# M09.13 — External commands through the shell (synchronous, +Errors)

**Status:** done on Linux/X11. Windows source-checks with pinned Odin
`dev-2026-11`; Windows execution is unvalidated.

## Behavior

A command executed by middle-click now runs directly in the shell:

- `|command` — pipe: selection becomes stdin, stdout replaces the selection.
- `<command` — replace: stdin is empty, stdout replaces the selection.
- `>command` — feed: selection becomes stdin, stdout goes to `+Errors`.
- `command` (plain, matching no built-in or named filter) — stdin is empty,
  stdout/stderr go to `+Errors`.

External commands run **synchronously** (blocking the event loop) by default;
`Async <cmd>` runs the same command through the M09 job service instead. Output
is appended to a single, reused `+Errors` buffer — no per-command job window and
no echo of the command text.

There is deliberately **no shell trust gate**: the user typed the command and
chose to run it. The shell is `cfg.Shell` when set, otherwise `sh` on Unix and
`cmd.exe` on Windows.

## Job management

`Jobs` opens a `+Jobs` buffer listing each running async job as
`id=<id> state=<state> command=<command>`. `Kill <id>` stops the job by id
(also via a button-1 chord selection); a second `Kill` forces SIGKILL. `Stop`
(no argument) still cancels every running job.

## Files

- `src/core/command/pipe.odin` — routing parse, shell argv, default shell.
- `src/pipe_ui.odin` — external execution: sync via `os.process_exec` (stdin
  through a temporary file), async via the job service.
- `src/command_ui.odin` — `Async` detection and the plain-command shell fallback.
- `src/editor.odin` — `editor_append_error_bytes` (shared bounded `+Errors` append).
- `src/core/config/schema.odin` — `shell` is now an optional override, not a gate.

## Tests

`pipe_parse`/`pipe_shell_command`/`pipe_default_shell` in
`tests/unit/command/pipe_test.odin`. `builtin-test` exercises plain, `|`, `<`,
`>`, no-echo, and `Async` on Linux/X11.

## Validation

```text
odin test tests/unit/command -vet -collection:hammer=src          -> 11/11 passed
odin test tests/unit/config -vet -collection:hammer=src           -> 20/20 passed
odin run make.odin -file -- process-test                          -> 28/28 passed
odin run make.odin -file -- test                                  -> all core suites passed
odin check src -vet -collection:sokol=third_party/sokol/sokol    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true -> passed
odin run make.odin -file -- builtin-test                          -> external-command scenarios passed on Linux/X11
git diff --check                                                  -> passed
```

## Trade-offs and not validated

Synchronous execution blocks the event loop, so a long-running command freezes
the editor; `Async <cmd>` is the escape hatch. Sync capture accumulates the full
output in the frame arena before truncating to the `+Errors` budget, so a
flooding command should use `Async`. Windows execution is source-checked only.
M09.11/M09.12 were skipped this session and remain pending.
