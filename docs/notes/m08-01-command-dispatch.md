# M08.01 — Command dispatch and context

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Parser and registry

`src/core/command/command.odin` provides the backend-free command boundary.
Input is limited to 64 KiB, surrounding whitespace is ignored, the command name
is separated from its trimmed remainder, and both returned strings borrow the
input. Empty and oversized input produce structured errors.

A registry is a caller-provided slice of exact, case-sensitive name/handler
entries. Dispatch reports whether an entry was registered separately from its
error, so a handler's own `NotFound` error cannot be mistaken for an unknown
command. Unknown names return `NotFound`; there is no shell or external-process
fallback. Registry lookup allocates nothing, and command input retains the
existing mouse action-text budget.

## Execution context and product routing

The command context captures the executing text target's kind, stable target,
window, column and buffer IDs, buffer generation and revision, selection,
command byte range, and borrowed file path. It also carries the last primary
selection as a distinct argument snapshot, including its stable identity,
generation, revision, and whether a 2-1 chord requested it. Invocation strings
and source paths are borrowed only for synchronous dispatch; snapshots own no
heap resources.

`src/command_ui.odin` replaces the button-2 string switch with registered
handlers for `Del`, `Exit`, `Put`, `Undo`, `Redo`, `Cut`, `Snarf`, `Paste`, and
`Look`. Source and argument targets are resolved and revalidated before use.
`Put` activates the captured source window when necessary rather than saving an
unrelated active buffer. Existing delayed clipboard behavior, literal/path
Look behavior, and the shared dirty-buffer close guard remain the execution
paths. Unknown text is logged and not executed.

`Text_Kind` now aliases the core source kind, and the editor stores its primary
argument snapshot as `command.Argument`, avoiding parallel context models.
`make.odin` includes the new unit package in the standard core test target.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/command -vet -collection:hammer=src
    -> 4/4 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 375 core unit tests passed, allocator tracking clean
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord checks passed, including 2-1 Look, Put,
       unknown-command non-execution, and safe Del
odin run make.odin -file -- compatibility-test --no-config
    -> all seven integrated compatibility stages passed
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
git diff --check
    -> passed
```

Unit coverage exercises borrowed parsing, empty and over-budget input,
exact-name routing, complete source/argument context delivery, unknown names,
missing handlers, propagated handler errors, and nil contexts. Product tests
used isolated Xvfb displays and temporary state. No native Windows/Wine run,
Wayland compositor, or real-desktop visual review was performed.

Additional built-in commands, addresses, Edit, external commands, and
asynchronous execution remain in their respective later tasks.

## Next task

M08.02 should implement backend-free line, character, and range address parsing
and evaluation. Cover document boundaries, current-selection defaults, valid
and malformed expressions, and out-of-range behavior with unit tests; leave
regular-expression addresses to M08.03.
