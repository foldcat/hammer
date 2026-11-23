# M10.detour-4 — Body-free commands and deterministic output placement

**Status:** done on Linux/X11; Windows source type-checking passed, but native
Windows execution was not exercised.

## Behavior

Plain external commands can run from global, column, and window tags without a
body window. The `>`, `<`, and `|` forms retain their existing source-body and
selection semantics.

Plain and explicitly output-routed commands open one bounded `+Job <id>` window
at the bottom of the rightmost column. If all columns were deleted, output
creation adds a column containing the job window rather than failing or
creating an unrelated empty buffer. Selection-routing forms instead write
successful stdout directly to the source buffer without a job window. Closing
a live job window still drains output without reopening it, and explicitly
discarding filter output remains unchanged.

## Implementation

- `src/pipe_ui.odin` requires a source body only for selection-routing forms.
  Plain commands retain the invocation's context snapshot and start with no
  source buffer.
- `src/job_ui.odin` owns output-column creation, initializes its column tag,
  and rolls the column back if buffer or window creation fails. Existing
  output uses the last column and the ordinary append-at-end window path.
- `tests/integration/builtins/x11_harness.py` checks rightmost placement for
  plain commands and verifies that pipe, replace, and feed commands open no job
  window. A separate scenario deletes every column, executes the purpose-built
  process helper from the global tag, and verifies that the command runs and
  opens output in a replacement column.
- `docs/specs/12-commands-console.md` and `docs/acme-compatibility.md` describe
  the invariant.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed; source check only, not Windows runtime validation
odin run make.odin -file -- builtin-test --no-config
    -> passed, including body-free global execution and rightmost output placement
odin run make.odin -file -- test
    -> all core unit tests passed
git diff --check
    -> clean
```

## Next task

Return to M10.07d: exercise complex terminal applications such as Neovim and
htop and verify their advertised terminal interactions.
