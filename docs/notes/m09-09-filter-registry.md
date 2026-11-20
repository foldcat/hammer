# M09.09 — Named filter-command registry, scoping, and discovery

**Status:** done on Linux/X11. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Declarative definitions

`src/core/command/filter.odin` owns a bounded registry of named commands. Each
definition contains a name, executable-engine name, raw body, output routing,
origin, scope, and a resolved engine path when available. Registration, lookup,
validation, directory discovery, and enumeration never execute a body or spawn a
process.

One `.filter` file describes one command using strict `key: value` lines:

```text
# Comments and blank lines are ignored.
name: sort-lines
engine: raku
routing: replace-selection
body: $*IN.lines.sort.join("\n")
```

All four keys are required and unique. Names start with an ASCII alphanumeric
and may then contain alphanumerics, `.`, `_`, or `-`. Engines are executable
names, not paths or shell fragments. Routing is `replace-selection`,
`output-window`, or `discard`. The body is the raw, nonempty, single-line value
after `body:`; multi-line program syntax is rejected explicitly rather than
misparsed. Definition files and bodies are limited to 64 KiB.

## Scopes, trust, and discovery

Lookup precedence is **session > project > user**. Duplicate names within one
scope are rejected; the same name may intentionally override a lower-precedence
scope. Scope reloads and clears are atomic, preserving the old registry on any
allocation, traversal, parse, validation, or registration error.

- User definitions load from `$XDG_CONFIG_HOME/hammer/commands` (or
  `~/.config/hammer/commands`) on Unix and `%APPDATA%/hammer/commands` on
  Windows. `Cmds user` reloads this trusted per-user directory and clears the
  scope if it disappears.
- Project definitions are not loaded automatically. `Cmds project` logs the
  explicit trust decision and loads `.hammer/commands` under the editor's working
  directory.
- Session definitions use the same registration API and never require a file.

Discovery scans only direct, regular `.filter` files, sorts their paths for
deterministic registration, and skips other file types and names. It is bounded
by 4096 scanned entries and 64 definitions. The registry itself holds at most 64
commands, 128 PATH directories, 64-byte names/engines, and 4096-byte paths.

Engine availability is detection only. The registry checks PATH candidates for a
regular executable file, requiring an execute permission bit on Unix and trying
the `.exe` suffix on Windows. Missing engines remain enumerable
as `available=missing`; they do not invalidate a definition.

## `Cmd` / `Cmds`

The global tag exposes `Cmds`; `Cmd` is an exact alias. With no argument, either
command opens a `+Commands` window listing names, scopes, engines, availability,
routing, and origins, sorted deterministically. Bodies are not copied into the
report. Each listing is a new bounded editor window, so a user-edited older report
is never overwritten. Named-filter invocation and echo-before-run remain M09.10.

## Tests

The command suite now has seven tests. New coverage includes parsing and
validation, precedence, duplicate and capacity rejection, deterministic reports,
available/missing engines, user/project/session behavior, scope clearing,
malformed-reload rollback, ignored file types, and missing directories. A marker
file proves that parsing, discovery, lookup, and enumeration do not execute a
body. Allocator tracking is clean, including the PATH-entry ownership path and
the borrowed-definition lifetime fixed during development.

The X11 built-in scenario loads a user definition automatically, explicitly
trusts a project override through `Cmd project`, checks available/missing engine
counts, and verifies that no definition body ran.

## Validation

```text
odin test tests/unit/command -vet -collection:hammer=src
    -> 7/7 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including 7 command tests
odin run make.odin -file -- builtin-test
    -> existing built-ins, jobs, selection conflicts, and quit decisions passed
    -> user/project discovery and no-execution scenario passed on Linux/X11
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check tests/unit/command -no-entry-point -vet -collection:hammer=src -target:windows_amd64
    -> product and command-test source checks passed
git diff --check
    -> passed
```

The pinned Odin toolchain does not provide an `odin fmt` command; no formatter
was run.

## Not validated and next task

Windows discovery was not executed natively. PATHEXT customization and multi-line
program bodies are not implemented in this slice. No named filter is invoked yet,
and no Raku runtime behavior is claimed.

Next: M09.10 should invoke a selected definition with an immutable context
snapshot, declared output routing, explicit echo before run, and the existing job
cancellation/stale-target safeguards.
