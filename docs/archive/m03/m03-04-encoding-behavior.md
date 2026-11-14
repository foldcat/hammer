## M03.04 done (2026-11-14 session)

Explicit unsupported/invalid encoding behavior
(`docs/notes/m03-04-encoding-behavior.md`) — byte-preserving display and
deliberate conversion in `src/core/filecodec`:

- `Display` owns valid UTF-8 text and coalesced `Offset_Map` spans. Valid text
  stays byte-exact; malformed UTF-8 bytes and all bytes of unsupported
  UTF-16/32 files display as `\xNN`. Raw/display mapping includes complete-file
  offsets, handles BOM exclusion and empty inputs, and rejects positions inside
  escapes. Original `Loaded` bytes remain unchanged.
- Invalid UTF-8 stays read-only and degrades parsing to plain text;
  unsupported encodings stay read-only with parsing disabled. Only valid UTF-8
  is initially editable/parser-eligible.
- `convert_to_utf8` creates independent owned UTF-8. It copies valid UTF-8 and
  decodes well-formed UTF-16/32 directly from chunks. Invalid UTF-8, malformed
  surrogates, invalid UTF-32 scalars, and truncated units require explicit
  `allow_lossy`; otherwise conversion returns `.Lossy_Confirmation_Required`
  without changing source state. Results record U+FFFD replacement counts.
- 11 new tests (21 total in `tests/unit/filecodec`) cover every mapping
  boundary, chunk splits, all Unicode BOMs, malformed wide input, 1000 seeded
  random inputs, allocation failure, and real loader/display/conversion.
- Validated: targeted 21/21 leak-free (×10 and single-threaded); full suite 163
  tests across 15 packages; debug/release builds; Xvfb release smoke; a
  `-no-crt` Windows consumer under Wine (invalid display/loss refusal and
  UTF-16LE surrogate conversion, exit 0). Real Windows and product-UI wiring
  remain unvalidated; saving is M03.05.
