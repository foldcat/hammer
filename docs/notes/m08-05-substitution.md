# M08.05 — Substitution progress

**Status:** partial on Linux/X11, at the user's requested scope. Only the
sed-style `s/regex/replacement/` command was implemented in this pass. M08.05
remains open. Windows source type-checking passes; native Windows/Wine runtime
was not exercised.

## Regex matching and captures

`src/core/address/regex.odin` extends the existing bounded Thompson executor
with ten capture groups (the full match plus `\\1`–`\\9`). The original address
behavior still uses no-capture compilation and passes its existing tests. The
executor can also limit the match end to an addressed range.

`src/core/address/search.odin` provides non-wrapping successive matches with
leftmost-longest semantics over the whole document's line-anchor context. It
advances empty matches by Unicode scalar, suppresses an empty match immediately
adjacent to the previous match, preserves explicit regex history, and returns
numeric capture ranges without exposing scratch memory. Result storage is
bounded; callers can request one extra match to detect budget overflow.

## Substitution parser and execution

`src/core/edit/edit.odin` parses `s`, including an optional occurrence number,
printable non-alphanumeric UTF-8 delimiters, escaped delimiters, empty-pattern
history, replacement escapes, and a trailing `g` after the closing delimiter.
The occurrence number is limited to 4096. `s2/re/text/g` starts at the second
match and replaces all subsequent matches.

`src/core/edit/substitute.odin` finds all required matches against the current
snapshot before editing. `&` expands the full match, `\\1`–`\\9` expand capture
groups, unmatched groups expand to nothing, and ordinary backslash pairs follow
Acme's replacement rules. All replacements are original-snapshot,
non-overlapping operations in one `.Edit` transaction. Generated output is
bounded to 64 MiB and at most 4096 replacements per command. No match returns
`.NotFound` without editing. Dot remains the addressed range, clamped to the
resulting document bounds.

Global substitution does not recursively match replacement text, and Undo/Redo
restores the whole substitution in one step. Execution remains synchronous;
cancellation belongs to M08.06.

## Product coverage

The existing product `Edit` handler executes substitutions without a separate
UI path. The X11 `edit-test` scenario now performs a global capture substitution
and verifies both the saved bytes and single-step Undo.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/address -vet -collection:hammer=src
    -> 27/27 tests passed, allocator tracking clean
odin test tests/unit/edit -vet -collection:hammer=src
    -> 18/18 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 420 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- edit-test --no-config
    -> existing Edit scenarios plus global capture substitution and undo passed
odin run make.odin -file -- mouse-test --no-config
    -> all existing mouse/modifier/chord checks passed
odin run make.odin -file -- compatibility-test --no-config
    -> all seven integrated compatibility stages passed
```

Coverage includes first, nth, global, and nth-plus-global substitutions;
addressed ranges; full and capture expansion; unmatched groups; escaped `&`,
backslashes, delimiters, and newlines; leftmost-longest alternatives; empty and
Unicode matches; line anchors; pattern history and no-match history updates;
invalid patterns; no-match atomicity; result budgets; and grouped undo/redo.

No native Windows/Wine run, direct Acme differential run, or cancellation was
performed. Differential fixtures remain M08.08.

## Deferred and next task

At the user's request, this pass did not implement loops/conditionals, braces,
`p`, `=`, `u`, file commands, pipes, `X`/`Y`, or other remaining Edit coverage.
Continue M08.05 with that remaining scope in a later session; do not advance to
M08.06 as though the task were complete.
