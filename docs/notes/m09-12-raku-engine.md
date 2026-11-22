# M09.12 — Raku temp-file programs, line filters, and REPL

**Status:** done on Linux/X11 with Rakudo v2026.09. Direct one-liners, named
`-n`/`-p` filters, temp-file cleanup, and interactive REPL input were exercised.
Windows is source-checked only.

## Running a one-liner

Middle-click a tag command such as:

```text
RakuEval say 2+2
RakuEval say $*CWD
```

`RakuEval` requires `raku` on the invocation-time `PATH`. It records the command
in the log without opening or writing `+Errors`, writes the raw argument to a
unique temporary `.raku` file, and starts `raku <file>` without a shell. A
non-empty selection becomes stdin; a collapsed caret feeds the entire current
unsaved buffer. Stdout and stderr appear in one bounded job output window.
`Stop`, `Kill`, backpressure, and quit-job decisions apply normally. There is no
native fallback for program evaluation.

For interactive use, middle-click:

```text
RakuRepl
```

This opens `raku` in the existing PTY terminal window. Type a one-liner and press
Enter; `exit` leaves the REPL. Resizing, terminal input, scrollback, process
reaping, and window close reuse `Win`'s implementation.

## Reusable named filters

Raku definitions use the existing registry and routing declarations. The
optional `raku` key accepts exactly `-n` or `-p`:

```text
name: upper
engine: raku
routing: replace-selection
raku: -p
body: $_ = $_.uc
```

Select text and middle-click `upper`. `-p` runs the body once per input line and
prints the resulting `$_`, so the example uppercases the selection. Use `-n` for
line processing without implicit print:

```text
name: show-lines
engine: raku
routing: output-window
raku: -n
body: .say
```

All named Raku filters use the same stdin rule: a non-empty selection supplies
its bytes, while a collapsed caret supplies the whole unsaved buffer. Ordinary
non-Raku output/discard filters retain their previous empty-stdin behavior.
`replace-selection` keeps the M09.06/M09.07 transaction and stale-target rules;
its output target remains the current selection or caret even when the input is
the whole buffer.
Definitions remain single-line metadata and are never executed by discovery or
`Cmds`; enumeration displays the declared Raku mode.

Program files are limited by the existing 64 KiB definition budget. They are
closed before spawn and owned by the retained job afterward. Release, failed
start, cancellation, and service destruction remove them. A tracking/allocation
failure stops the new job and removes the caller's file. Temporary path strings
and job-owned copies use matching explicit allocators.

The M09.11 `Raku /pattern/` search adapter is unchanged. General addresses and
`Edit` still use only the native regex engine. Placeholder interpolation,
multi-line definition bodies, and a general multi-argument filter syntax are not
part of this slice.

## Tests

- Command tests cover temp-file argv construction, `-n`/`-p` declarations,
  duplicate/invalid modes, registry cloning, and non-Raku mode rejection.
- Process tests prove job release removes an owned temporary file, reject
  duplicate or stale attachment, copy discard-job stdin, and cover the
  selection-or-whole-buffer selection-pipe input rule.
- The X11 built-in scenario runs a real `-p` uppercase replacement and saves its
  bytes, proves `-n` receives selection stdin, and executes `RakuEval` first with
  a collapsed caret over unsaved text and then with an eight-byte highlight. It
  checks log echo-before-run, exactly one job window per Raku invocation, no
  `+Errors` activity, and an isolated `TMPDIR` empty after completion.
- The X11 terminal scenario opens a real Raku REPL, evaluates typed input with
  an observable result, exits it, and reaps the PTY child.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin test tests/unit/command -vet -collection:hammer=src
    -> 13/13 passed
python3 tests/unit/process/process_harness.py --repo /home/user/Projects/hammer
    -> 44/44 passed
odin run make.odin -file -- builtin-test
    -> all existing and new RakuEval/-n/-p/temp-cleanup scenarios passed
odin run make.odin -file -- terminal-test
    -> existing terminal checks and real RakuRepl scenario passed
odin run make.odin -file -- test
    -> full core suite passed, including 13 command and 44 process tests
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/command -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> Windows product and test source checks passed
git diff --check
    -> passed
```

Two initial integration failures diagnosed fixture issues rather than process
lifetime bugs: the first uppercase body used invalid Raku syntax, and the X11
typing helper needed explicit shifted-symbol handling. The corrected fixtures
pass; no assertion or error path was suppressed.

## Not validated and next task

Native Windows/Raku execution, ConPTY REPL behavior, and multi-line `.filter`
programs were not exercised or implemented. Raku REPL line editing depends on
the installed Raku runtime and its available line-editor modules.

Next: return to M10.07d and exercise complex terminal applications such as
Neovim and htop, with resize, alternate-screen, input, color, and clean process
shutdown checks.
