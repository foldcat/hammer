# M09.10 — Command invocation with context snapshot and routing

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Invocation contract

`src/filter_invoke.odin` (package main) wires the M09.09 registry into the
M09.04/M09.06 job machinery. When a mouse or keyboard execute resolves an
unknown built-in name, `editor_execute_mouse` falls back to
`editor_invoke_filter`, which looks the name up in the filter registry. Unknown
names still log and no-op exactly as before; a matched name is handled even
when invocation fails.

A matched definition is invoked with:

1. An immutable `process.Context_Snapshot` built from `command.Source`. The body
   window (when present) supplies the stable `ACME_BUFFER_ID`, the directory
   flag, and the file path; tag identity and a borrowed path are used otherwise.
   Working-directory precedence and reserved-variable replacement are the M09.04
   behavior, unchanged.
2. The declared routing. `replace-selection` starts a `job_start_selection` on
   the body's current selection (so later edits raise the existing M09.07
   stale-target conflict and preserve output for `Apply`). `output-window` and
   `discard` start context jobs; discard marks the job so the poll loop drains
   records without opening a window.
3. An explicit echo before run: a `filter: echo %q` log line plus the resolved
   `engine body` line appended to `+Errors`, both emitted before the job starts.

Filter commands take no arguments: a nonempty invocation argument is rejected,
and a definition whose engine path is unresolved is rejected before spawning.

## Command vector

`command.filter_command` builds the argument vector for a resolved definition:
the engine executable (`argv[0]`) followed by the raw body as a single program
argument (`argv[1]`). The engine interprets that argument (awk/sed-style filters
and purpose-built helpers); engine-specific adapters such as Raku's
`-e`/temp-file convention remain M09.12. The caller owns the vector and each
element and releases them with `command.filter_command_destroy`.

## Discard routing

`job.odin` adds a `discard_output` flag and `job_start_context_discard`, which
starts a context job and marks it to discard all stdout/stderr. The job still
participates in cancellation, quit-blocking, and slot lifecycle. The editor poll
loop drains discard records without allocating an output buffer and reports
spawn/pump errors directly instead of through a nonexistent window.

## Tests

The command suite now has eight tests; new coverage exercises the command
vector, missing-engine rejection, and nil-definition rejection. The process
suite now has 27 tests; the new case starts a discard job, verifies the flag and
an empty selection pipe, drains the real child's stdout/stderr, and confirms a
successful release.

The X11 built-in scenario adds three named filters backed by the purpose-built
helper: `invoke-pipe` (replace-selection) replaces the whole-body selection and
saves exact UTF-8 bytes with the echo observed before the start; `invoke-out`
(output-window) opens and drains a bounded job window; `invoke-discard`
(discard) writes its marker file and provably opens no output window.

## Validation

```text
odin test tests/unit/command -vet -collection:hammer=src
    -> 8/8 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including 8 command and 27 process tests
odin run make.odin -file -- builtin-test
    -> existing built-ins, jobs, selection conflicts, quit decisions, and
       discovery passed; the three filter-invocation scenarios passed on Linux/X11
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/command -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product and test source checks passed
git diff --check
    -> passed
```

The pinned Odin toolchain does not provide an `odin fmt` command; no formatter
was run.

## Not validated and next task

Windows filter invocation was not executed natively. The generic engine receives
the body as a single positional argument; Raku's `-e`/temp-file adapter,
`-n`/`-p` filters, and the REPL window remain M09.12. General `>`, `<`, and `|`
tag command routing is still separate (M09.detour-1 for the tagbar `|`).

Next: M09.11 should implement the optional external regex verb (Raku when
present, native fallback).
