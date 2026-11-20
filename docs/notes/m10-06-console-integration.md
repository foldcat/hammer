# M10.06 (slice 1) — Console stream integration into the output pipeline

**Status:** done on Linux (log-output half). The console stream and the process
output integration are pure Odin (no FFI, no platform imports); the packages and
tests `odin check` clean on `windows_amd64`, but no Windows runtime result is
claimed. The `win` terminal window (model B) is the remaining half of M10.06.

## What was built

`src/core/console/stream.odin` (package `console`) composes the M10.01-M10.04
primitives into one stateful `Stream` that turns raw process output bytes into
clean UTF-8 text:

- `Stream` holds a `Decoder` + `Parser` + `Line_Buffer` plus reused scratch
  buffers (512 runes / 512 events) and a transient completed-line list. It is a
  fixed-location value; init/destroy are `stream_init`/`stream_destroy`.
- `stream_feed(input, out)` consumes all input and appends decoded clean text:
  ANSI/OSC sequences are consumed deterministically, CR/backspace/erase edits
  collapse in-place progress, and each completed line is emitted with its
  trailing newline restored. A partial trailing line stays in the stream.
- `stream_flush(out)` emits end-of-stream state — a truncated UTF-8 sequence
  becomes one U+FFFD, and the trailing partial line is emitted — idempotently.
- Style runs and hyperlinks are computed by the line buffer but not rendered:
  the caller gets plain text (readable/selectable). Per-run color rendering and
  style storage are a later milestone (SPECS §12.7).

`src/core/process/output.odin` now decodes before the document. `Output_Buffer`
owns a `console.Stream` and a growable `decoded` byte buffer; `output_flush`
feeds `pending` through the stream and appends the decoded bytes (scrollback
trimming unchanged). Because `output_consume`, `output_append`,
`selection_pipe_consume` (stderr), and `selection_pipe_replay` all funnel
through `pending`+`output_flush`, every output-window path decodes uniformly.
`output_finish` flushes the stream's trailing state and is called by
`editor_poll_jobs` (job_ui.odin) just before a job is released, so a trailing
line without a newline is not lost.

## Ownership and bounds

The stream and decoded buffer are owned by `Output_Buffer` and released by
`output_destroy`. The decoded buffer grows as needed; its worst case is a single
line carried to the line buffer's cell budget (`max_cells`, default 64 KiB cells)
then completed in one flush — bounded by that cell budget plus one batch, and
only in the pathological no-newline case. A line held across a batch boundary
is emitted whole, so one insert may be up to `batch + carried line` rather than
the old strict `batch`; the scrollback bound is unchanged.

## Tests

- `tests/unit/console/stream_test.odin` (9 tests): plain passthrough, ANSI
  stripping, CR/backspace/erase progress, OSC hyperlink consumption, partial-line
  hold-until-flush (and idempotent flush), truncated-UTF-8 replacement,
  multi-byte passthrough, and chunk-boundary invariance (whole vs byte-at-a-time).
- `tests/unit/process/output_test.odin`: rewrote the append/trim test for
  newline-terminated decoded lines and added `test_output_decodes_ansi_progress_and_tail`
  (helper `ansi` mode: colored text, a CR progress update, and a no-newline tail
  are decoded to clean text end to end through a 4-byte-chunk pump).
- `tests/unit/process/selection_test.odin`: the explicit-apply test now calls
  `output_finish` before reading the replayed diagnostics, matching the new
  partial-line semantics.
- `tests/unit/process/helper/main.odin`: added the `ansi` mode.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src        -> 61/61 passed
odin run make.odin -file -- process-test                        -> 36/36 passed
odin run make.odin -file -- test                                -> full core suite passed
odin check src -vet -collection:sokol=third_party/sokol/sokol   -> passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> passed
odin check tests/unit/console -vet -no-entry-point -collection:hammer=src -target:windows_amd64 -> passed
odin check tests/unit/process -vet -no-entry-point -collection:hammer=src -target:windows_amd64 -> passed
odin run make.odin -file -- builtin-test                         -> flood drains through the real output window (22 scenarios passed)
git diff --check                                                 -> passed
```

## Not validated and next task

Per-run ANSI colors are computed but not rendered (single-color glyphs); style
storage separate from text (SPECS §12.7) is deferred. The OSC clipboard policy
(`Control_Policy.allow_clipboard`) is still not wired to the platform/UI
clipboard layer. Windows runtime behavior is not exercised (no Windows toolchain
here). The `win` terminal window (model B: PTY + input forwarding) is the
remaining half of M10.06, and the terminal grid (cursor addressing, alternate
screen, resize, raw input) is M10.07.
