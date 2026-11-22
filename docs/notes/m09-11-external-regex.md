# M09.11 — Optional external regex verb

**Status:** done on Linux/X11 with real Raku execution and native-fallback tests.
Windows source compatibility is checked separately; native Windows execution is
not claimed.

## Command contract

`Raku /pattern/` is an explicit forward-search verb over the current window body.
It starts at the end of dot and wraps once, like the native forward address
regex. Only one forward `/pattern/` expression is accepted; general addresses,
backward search, and `Edit` remain entirely on the native engine.

The command resolves `raku` on the invocation-time `PATH` snapshot:

- Present: log the invocation without opening `+Errors`, then run the fixed adapter as
  `raku -e <program> <pattern> <dot-byte>` without a shell. Raku regex syntax and
  leftmost-first behavior apply. The whole body is an immutable stdin snapshot.
- Absent: synchronously evaluate the same `/pattern/` with the existing native
  Odin engine. Normal `/re/`, `?re?`, and `Edit` behavior is unchanged.
- Present but failing, invalid, or finding no match: report that outcome; do not
  silently switch engines.

An empty pattern reuses the buffer's existing regex history in either mode.
Successful search changes only the selection and scroll position, not buffer
contents, dirty state, or undo history.

## External result boundary

`process.Regex_Search` owns a whole-document input snapshot capped at 16 MiB and
a 128-byte stdout result. The Raku adapter converts match offsets back to UTF-8
byte offsets and emits exactly `start end`. Stderr uses the ordinary bounded job
output window. Exit status 4 reports no match.

Completion validates the job/request ID, buffer ID and generation, source view,
and exact source revision before applying the selection. Any newer source edit
rejects the result as a conflict. Returned offsets are checked for document
bounds and UTF-8 scalar boundaries. `Stop`, `Kill`, output backpressure, and the
running-job quit guard apply through the existing job service.

The fixed `-e` adapter is specific to this verb. General Raku temp-file program
execution, `-n`/`-p` named filters, and the REPL window remain M09.12.

## Tests

- Command unit coverage checks that the fixed program, user pattern, and start
  offset remain separate argv entries, including empty-pattern and invalid-input
  handling.
- Process unit coverage checks Unicode byte ranges, document immutability,
  malformed result handling, UTF-8 scalar boundaries, stale identity,
  and stale source revisions.
- The Linux/X11 built-in scenario runs real `raku` through forward, second-match,
  and wraparound searches with non-ASCII text before the second match. A second
  editor run with an empty `PATH` proves native fallback and no external spawn.
  The external echo is observed before job start.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin test tests/unit/command -vet -collection:hammer=src
    -> 12/12 passed
python3 tests/unit/process/process_harness.py --repo /home/user/Projects/hammer
    -> 41/41 passed under the standard serialized external-timeout harness
odin run make.odin -file -- builtin-test
    -> all existing scenarios passed
    -> real Raku forward/wraparound/UTF-8 selection scenario passed
    -> native fallback without PATH Raku passed
odin run make.odin -file -- test
    -> full core suite passed, including 12 command and 41 serialized process tests
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/command -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> Windows product and test source checks passed
git diff --check
    -> passed
```

A direct non-serialized `odin test tests/unit/process` run also exercised the new
tests successfully, but exposed existing parallel-sensitive failures in
`test_job_stop_attachment_is_selective`, `test_pty_resize_reaches_child`, and
`test_failed_exec_closes_partial_pipe_sets`. The standard serialized harness
passed; those unrelated tests were not changed.

## Not validated and next task

Native Windows/Raku execution and interactive cancellation of a pathological
Raku regex were not exercised. Raku and native regex dialects intentionally
differ when Raku is present; fallback is based on executable absence, not on
pattern compatibility.

Next: M09.12 should implement general Raku named-filter adapters using temp-file
programs, `-n`/`-p`, and a REPL window without changing the native address
language invariant.
