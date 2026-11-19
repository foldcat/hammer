# M08.04 — Documented Edit command subset

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Parser and execution

`src/core/edit/edit.odin` implements a bounded parser for the foundational Sam
text commands: bare addresses, `a`, `c`, `i`, `d`, `m`, and `t`. Input is
limited to 64 KiB and 128 commands. Delimited text supports printable non-
alphanumeric UTF-8 delimiters, escaped delimiters, `\n`, and Acme's otherwise
literal backslash behavior. Multiline text ends at a line containing only `.`.
Move/copy destinations use simple addresses. Parsing the whole invocation
finishes before any mutation; malformed input does not edit the buffer, while
unsupported commands return `.Unsupported`.

`src/core/address/address.odin` now exposes prefix parsing for an address
followed by a command. Only the consumed address counts toward its 4 KiB
budget, not the remaining Edit script. Missing range operands can end at the
command byte, so forms such as `1,d` retain their normal defaults.

`src/core/edit/execute.odin` applies commands sequentially, with each command's
address evaluated against the current intermediate document and dot. Every
mutation goes through `txn.doc_apply` with source `.Edit`. All transactions in
one invocation share a nonzero undo group, distinct from the preceding group,
so one Undo reverts the invocation and one Redo reapplies it. A runtime error
leaves already executed commands in that group, matching Acme's sequential
behavior; syntax errors are atomic. Dot is set to each command's result for
address, append/change/insert, and deletion commands. M08.08 corrected move/copy
to preserve the previous dot, matching Acme rather than Sam's result dot.

Move uses original-snapshot insert/delete operations in both destination
orders and rejects overlap with its source. Copy reads the source before
insertion, including when the destination lies inside it. Move/copy ranges are
limited to 64 MiB. Selection endpoints are checked for document bounds and
Unicode scalar boundaries. Regex addresses reuse the explicit M08.03 history;
there is no second regex engine or implicit global history.

## Product integration

`Edit` is registered in `src/command_ui.odin`. It resolves the executing
window's body, parses inline arguments, and supports a 2-1 chord script read
from the revalidated primary selection. Regex history is value-owned by each
`Editor_Buffer`. Multi-command invocations transform selections in every other
view once per transaction, using that transaction's post-edit byte count, and
refresh dirty tags after execution.

`make.odin` includes `tests/unit/edit` in the standard core tests and adds
`edit-test`. The X11 harness uses isolated state and real keyboard/mouse input
to execute tag scripts through the ordinary mouse-action path, then verifies
saved bytes for multiline change, addressed delete, undo, move, and move undo.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/address -vet -collection:hammer=src
    -> 25/25 tests passed, allocator tracking clean
odin test tests/unit/edit -vet -collection:hammer=src
    -> 12/12 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 412 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- edit-test --no-config
    -> multiline change, delete, undo, move, and move undo passed on X11
odin run make.odin -file -- mouse-test --no-config
    -> all existing mouse/modifier/chord checks passed
odin run make.odin -file -- compatibility-test --no-config
    -> all seven integrated compatibility stages passed
```

Unit coverage includes default and explicit dots, delimited and multiline text,
Unicode delimiters and scalar-boundary errors, escapes, open ranges, long text
following an address prefix, sequential edits, regex history, move/copy in both
orders, overlap rejection, malformed and unsupported commands, command budgets,
zero-length edits, runtime errors after mutation, and grouped undo/redo across
separate invocations.

No native Windows/Wine run, direct Acme differential run, asynchronous
cancellation, or dedicated 2-1 Edit chord UI scenario was performed. The chord
path has product wiring but only the inline-script path was exercised by the
X11 harness. Differential fixtures remain M08.08.

## Remaining Edit coverage

Loops and conditionals (`x`, `y`, `g`, `v`, braces), display and file commands,
pipes, and the rest of the documented language remain M08.05 and later tasks.
Substitution (`s`) was subsequently implemented; see
`docs/notes/m08-05-substitution.md`. The core executor supports synchronous use;
product execution subsequently moved to the cancellable snapshot runner in
`docs/notes/m08-06-async-edit.md`. Atomic multi-buffer validation remains M08.07.

## Next task

M08.05 should complete required Edit coverage on top of this parser/executor,
prioritizing substitution and loop commands while preserving one undo group per
invocation and the existing native regex/history semantics.
