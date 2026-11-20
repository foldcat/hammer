# M10.01 — Chunk-safe UTF-8 decoder

**Status:** done on Linux. The decoder is pure Odin (no FFI, no platform
imports, no allocation); the package and tests also `odin check` clean on the
`windows_amd64` target, but no Windows runtime result is claimed.

## What was built

`src/core/console/decode.odin` (package `console`) adds a streaming UTF-8
decoder that carries an incomplete multi-byte sequence across chunk
boundaries, so process output that arrives split (confirmed real in
`m00-07-pty.md`, Finding 3) decodes byte-exactly regardless of where chunks
happen to land.

- `Decoder` is a fixed-location, allocation-free value (`pending: [4]u8`,
  `pending_len`, `want`, `first_lo`/`first_hi`, and a `replacements: u64`
  counter). The zero value is an idle decoder.
- `decode(d, input, out) -> (written, consumed)` appends decoded Unicode
  scalar values to the caller's rune buffer and returns how much input it
  consumed. A buffer of `len(input)+1` runes always consumes all of `input`;
  smaller buffers make partial progress and the caller resumes with the
  remaining input.
- `finish(d) -> (rune, bool)` flushes a truncated trailing sequence as one
  U+FFFD and returns whether anything was pending.

Invalid bytes are replaced deterministically using the Unicode "maximal
subpart" rule (Conformance clause C10): the longest well-formed prefix of an
ill-formed sequence becomes exactly one U+FFFD. So `E1 80 A` yields
`U+FFFD A` (the `E1 80` prefix is one subpart), and `E0 80 80` yields three
replacements (E0's first continuation is out of range, so only E0 is the
subpart, then `80` and `80` are isolated continuations). Overlong, surrogate,
and out-of-range leads are rejected by per-lead first-continuation ranges.

## Why not reuse `filecodec`

`filecodec` already validates UTF-8 (M03.03), but it only *classifies*
(`Valid_UTF8` / `Invalid_UTF8` / `Unsupported_Encoding`) and never *emits*
scalars; and its policy for invalid bytes is byte-preserving read-only, which
is wrong for a terminal stream that must render something. The console
decoder produces a rune stream for the ANSI state machine (M10.02) and uses
the standard replacement policy instead.

## Tests

`tests/unit/console/decode_test.odin` (package `console_test`), 8 tests:

- ASCII passthrough at every chunk size.
- Every boundary scalar (U+0000, U+007F, U+0080, U+07FF, U+0800, U+D7FF,
  U+E000, U+FFFF, U+10000, U+10FFFF) split at every byte position.
- Valid strings (CJK, emoji, combining marks) match the pinned stdlib
  `for r in s` reference at every chunk size.
- The maximal-subpart replacement table (18 ill-formed cases) at every split.
- Replacement counter for a mixed invalid stream.
- Chunk-boundary invariance: 2000 pseudo-random byte streams decoded whole,
  byte-at-a-time, and at a random split must agree exactly.
- Partial consumption: a 2-rune buffer reassembles a mixed-script string to
  match whole-at-once decoding.
- `finish` truncation and idempotence.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src
    -> 8/8 tests passed
odin check src/core/console -vet -no-entry-point
odin check src/core/console -vet -no-entry-point -target:windows_amd64
odin check tests/unit/console -vet -no-entry-point -collection:hammer=src -target:windows_amd64
    -> package and tests source-check clean on Linux and windows_amd64
odin run make.odin -file -- test
    -> full core unit suite passed, including the new console package
```

## Not validated and next task

Windows runtime behavior is not exercised (no Windows toolchain here; the
decoder has no platform code, so this is low risk but still unclaimed). The
decoder is not yet wired into `process.output_consume`; that integration
belongs to M10.02, which builds the ANSI state machine and SGR style model on
top of this rune stream.

Next: M10.02 — Implement ANSI state machine and SGR styles.
