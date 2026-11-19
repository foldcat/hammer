# M08.08 — Differential compatibility fixtures

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows runtime was not exercised.

## Fixtures and reference provenance

`tests/unit/acme/fixtures/acme-edit.json` contains 15 address and 20 Edit cases.
The fixtures cover absolute/relative line and character addresses, Unicode byte
offsets, comma/semicolon ranges, forward/backward regular expressions,
leftmost-longest matching, empty matches and wraparound, no-match errors,
foundational text edits, move/copy in both directions, sequential commands,
substitution occurrence/global/capture/empty/Unicode behavior, and runtime-error
prefixes.

`tests/unit/acme/generate_fixtures.py` regenerates the JSON using the installed
Plan 9port `sam -d` in a fresh temporary directory per case. It uses no 9P,
Acme control files, or Hammer IPC. Normal tests need only the checked-in JSON;
Sam is required only when regenerating or running `--check`. Reference character
offsets are converted to UTF-8 byte offsets explicitly.

Sam and Acme differ in some resulting-dot behavior. Content and address results
come from Sam. Cases marked `acme_dot` in the generator instead use the prior or
addressed dot specified by Acme's `ecmd.c`: Acme `m`/`t` preserve the previous
dot, while `s` retains the addressed range. The override is removed from the
generated JSON, and the source of these expectations is recorded here and in
the fixture metadata. No direct Acme runtime comparison is claimed.

## Core runner and corrections

`tests/unit/acme/acme_test.odin` decodes the bounded static fixture set with the
pinned Odin JSON package, initializes one-byte-chunk documents, and compares
errors, exact content, ranges, and dots. All fixture strings and arrays have
explicit cleanup. `make.odin` includes the package in the standard core suite.

The reference fixtures exposed and pinned two compatibility corrections:

- `src/core/address/regex.odin` now retries one Unicode scalar past an empty
  regex address at the search origin, wrapping at either end. This applies to
  forward and backward searches and matches the reference `nextmatch` rule.
- `src/core/edit/execute.odin` now preserves the previous dot for move/copy,
  including self-moves and empty ranges, clamping it to the resulting document.
  Edit contents, transaction ordering, and undo grouping are unchanged.

Existing address and Edit unit expectations were updated to these reference
semantics. Substitution retains Hammer's existing Acme-compatible addressed dot;
it was not changed to Sam's different result.

## Validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
python3 tests/unit/acme/generate_fixtures.py --check
    -> 15 address and 20 edit fixtures reproduced with sam -d
odin test tests/unit/acme -vet -collection:hammer=src
    -> 2/2 test procedures passed, all 35 fixtures, allocator tracking clean
odin test tests/unit/address -vet -collection:hammer=src
    -> 28/28 tests passed
odin test tests/unit/edit -vet -collection:hammer=src
    -> 25/25 tests passed
odin run make.odin -file -- test
    -> all 430 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- edit-test --no-config
odin run make.odin -file -- compatibility-test --no-config
    -> both X11 harnesses passed
git diff --check
    -> passed
```

No native Windows/Wine runtime, direct Acme UI differential, unsupported Edit
commands, or product Look address integration was exercised. Fixture generation
was validated against the installed Plan 9port Sam; the static tests do not
require that installation.

## Next task

M08.09 should implement New, Newcol, Zerox, Delcol, Get, and Putall through the
existing command dispatch, view/buffer ownership, file-state, and uniform dirty-
close state machines, with isolated core and X11 coverage.
