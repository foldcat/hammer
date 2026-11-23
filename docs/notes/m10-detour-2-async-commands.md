# M10.detour-2 — All external commands are jobs

**Status:** done on Linux/X11; Windows source type-checking passed, but native
Windows execution was not exercised.

## Behavior

Every external shell command now starts through the job service immediately.
The blocking `os.process_exec` executor and the `Async` command prefix are gone.
Built-in editor actions remain immediate UI operations. Plain commands and the
`>`, `<`, and `|` routing forms retain their selection/stdin semantics, with
revision-validated asynchronous replacement for `<` and `|`.

Each invocation has one bounded live `+Job <id>` output window rather than
routing plain/feed output to `+Errors`. Closing a live output window switches
the job to bounded output draining: the window is not reopened, the process is
not killed, and `Jobs` still lists it so `Kill <id>` can stop it. This also
removes the dangling output-buffer pointer that closing a job window previously
left behind.

## Implementation

- `src/command_ui.odin` no longer recognizes or strips `Async`.
- `src/pipe_ui.odin` contains only the job-service execution path; synchronous
  capture, temporary stdin files, and direct selection replacement were removed.
- `src/job_ui.odin` resets closed output state and marks the matching job as
  drain-only while preserving its stable ID for `Jobs`/`Kill`.
- `src/editor.odin` routes job-output destruction through that close handler and
  uses the same reset helper during application teardown.
- `docs/specs/12-commands-console.md` and `docs/acme-compatibility.md` describe
  the current behavior.

## Tests

The built-in X11 scenario now checks:

- Plain, pipe, replace, and feed commands each create exactly one job output
  window and no `+Errors` output window.
- `<` and `|` replace selections asynchronously with the expected file bytes.
- `Async` has no special prefix behavior and is passed to the shell as text.
- A long-running plain command stays active after its output window is closed,
  does not reopen that window, appears in `Jobs`, and is killed by ID.

Validation:

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- builtin-test
    -> all built-in, routing, output-close, Jobs, and Kill checks passed
odin run make.odin -file -- test
    -> all core unit tests passed
odin run make.odin -file -- typing-test
    -> passed
odin run make.odin -file -- compatibility-test
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed; source check only, not Windows runtime validation
git diff --check
    -> clean
```

## Next task

Return to M10.07d: exercise complex terminal applications such as Neovim and
htop and verify their advertised terminal interactions.
