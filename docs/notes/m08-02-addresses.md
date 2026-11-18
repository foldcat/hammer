# M08.02 — Line, character, and range addresses

**Status:** done as a backend-free core on Linux. The unchanged product passes
Linux and Windows source checks; no native Windows runtime was exercised.

## Parser and representation

`src/core/address/address.odin` parses addresses into a fixed-capacity typed
AST. Successful parsing allocates nothing and retains no borrowed input. The
limits are 4 KiB of source text, 128 simple-address operations, and 32 range
levels; exceeding them returns `Resource_Limit` rather than growing storage or
recursing without a bound.

Supported forms are:

- `0` and one-based decimal line addresses, `.` for the current dot, and `$`
  for end of text.
- Zero-based `#n` character addresses.
- `+`/`-` relative line or character motion, including the implicit one-line
  motion of a bare sign and implicit forward motion between adjacent numbers.
- `,` ranges and `;` ranges. Missing left/right sides default to `0`/`$`;
  semicolon makes the left result the right side's dot.

Malformed syntax returns `Invalid_Input`. `/.../` and `?...?` are implemented
by M08.03; see `docs/notes/m08-03-regex-addresses.md`.

## Evaluation

`src/core/address/evaluate.odin` evaluates the AST against a rope and a byte
range dot. Character arithmetic uses the rope's Unicode scalar metrics and
converts the final scalar offset back to bytes. Relative character operations
reject a dot in the middle of a multi-byte scalar. Results are ordered,
bounds-checked `rope.Byte_Range` values suitable for later transaction and Edit
consumers.

Line addressing follows Acme's LF model: line ranges include their trailing LF;
a final unterminated line ends at the document end; a trailing LF creates a
final empty line. CR is an ordinary character, while the LF in CRLF terminates
the line. `0` is the empty address at the start. Valid addresses that do not
exist return `NotFound`; reversed compound ranges return `Invalid_Input`.

Line lookup scans borrowed rope data through a fixed 16 KiB buffer in both
directions. It does not flatten the document, and evaluation allocates only
structured errors. Worst-case work is proportional to the scanned document.
This remains synchronous; snapshot execution and cancellation for expensive
edits belong to M08.06.

This task implements the core parser/evaluator only. Product Look retains its
existing simple `file:line` behavior, and no Edit command is claimed yet.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/address -vet -collection:hammer=src
    -> 11/11 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 386 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both unchanged-product source checks passed
git diff --check
    -> passed
```

The address tests use chunked ropes and cover absolute/relative lines and
characters, Unicode scalar-to-byte conversion, dot and end, comma/semicolon
ranges and defaults, nested ranges, empty documents, trailing newlines, lone CR
and CRLF, scans crossing the 16 KiB buffer, malformed syntax, numeric overflow,
operation/range budgets, out-of-range motion, reversed ranges, invalid dots, and
nil evaluator inputs. Regex forms were unsupported at this stage; M08.03 adds
their implementation and coverage.

No native Windows/Wine run, direct differential run against Acme, or product UI
address execution was performed. Differential compatibility fixtures remain
M08.08.

## Follow-up

M08.03 added forward/backward regular-expression addresses, delimiter escaping,
previous-pattern history, and Unicode/chunked-rope matching. See
`docs/notes/m08-03-regex-addresses.md`.
