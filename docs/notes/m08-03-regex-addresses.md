# M08.03 — Compatible regular-expression addresses

**Status:** done as a backend-free core on Linux. Linux and Windows source
checks and the normal Linux product build pass; no native Windows runtime or
product UI address execution was exercised.

## Address forms and history

`src/core/address/address.odin` now parses `/re/` and `?re?` as typed regex
operations in the existing fixed-capacity AST. Patterns are copied into the
expression's 4 KiB inline storage; parsing still allocates nothing and retains
no borrowed source text. Escaped delimiters, adjacent regex operations, range
operands, and `+`/`-` direction and origin rules are supported. A literal
newline or missing closing delimiter is rejected.

`evaluate` remains the stateless entry point. `evaluate_with_history` also
accepts a zero-initialized, value-owned `Regex_History`; a successfully compiled
nonempty pattern replaces it, including when no match is found. `//` and `??`
reuse that pattern, and an empty history returns `Invalid_Input`. Invalid new
patterns do not destroy the previous history. No global regex state is shared
between buffers or tests.

## Native matching semantics

`src/core/address/regex.odin` uses only Odin's native regex parser/compiler and
a bounded Thompson-thread executor. There is no Raku or other external-engine
fallback (R-01).

The adapter implements the Acme/Plan 9 behavior needed by addresses:

- Unicode scalar matching over text read from chunked ropes.
- Leftmost-longest forward matches rather than alternative-order priority.
- Backward searches by reversing Unicode text, reversing regex concatenation,
  and swapping line anchors, matching Sam's backward execution model.
- Wraparound in both directions; a wrapped match may straddle the starting dot.
- `.` and negated classes exclude LF, while `\n` matches it explicitly.
- `^` and `$` are zero-width line anchors; `$` does not consume the LF.
- Plan 9 literal escaping, including escaped delimiters, ordinary escaped
  letters such as `\d`, and literal braces and `#` rather than Odin extensions.
- Zero-length matches, no-match `NotFound` errors, and malformed-pattern
  `Invalid_Input` errors.

The optional start anchor prepend forces the pinned compiler's generic search
prefix instead of its prioritized literal-search shortcut. The executor keeps
at most one thread per program counter per input position, so execution is
bounded by `O(document_scalars * program_size)`; there is no backtracking or
exponential retry path. Source group nesting is limited to 32 and compiled
engine capacity errors return `Resource_Limit`.

Each regex operation uses a growing virtual arena for its contiguous text,
compiled program, reversed text when needed, and thread storage. The arena is
`free_all`ed and destroyed on every return. Structured errors use the caller's
allocator, not the scratch arena. Memory is `O(document_bytes + program_size)`.
Evaluation remains synchronous; snapshot execution and cancellation for long
operations are M08.06 work.

## Tests and validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/address -vet -collection:hammer=src
    -> 25/25 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 400 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file
    -> normal Linux debug product build passed
git diff --check
    -> passed
```

Coverage includes forward/backward wraparound, reversed concatenation and
backward greediness, matches straddling dot, leftmost-longest alternatives,
zero-length matches, line anchors, LF rules, escaped delimiters and Plan 9
literals, explicit history and no-match history updates, malformed syntax,
Unicode classes and scalar reversal, one-byte rope chunks, matches crossing the
16 KiB scan boundary, sign direction/origin, AST fields, and group budgets.

No native Windows/Wine run, direct differential run against Acme, cancellation,
or product Look/Edit integration was performed. Direct differential fixtures
remain M08.08; this task used the published Sam/regexp manuals and Plan 9
reference source to define expected behavior.

## Next task

M08.04 should implement the first documented Edit command subset in dependency
order, applying all mutations through coherent transactions and reusing the
native regex/history behavior rather than introducing a second engine.
