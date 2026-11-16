# M05.04 — Shaping and positioned runs

**Status:** done; Linux native shaping, bidi ordering, and cluster fallback are
validated. The product does not draw the resulting runs yet.

## Shaping pipeline

`src/text/shaping` accepts one valid UTF-8 line, a bounded ordered font list,
and shaping options. Input is limited to 1 MiB and sixteen fonts per call; visible-
range slicing for huge lines remains M05.07. Empty input succeeds with no runs;
invalid UTF-8 and embedded line breaks fail without retaining partial output.

1. Decode UTF-8 while building UTF-16, codepoint, and absolute source-byte maps.
2. Use ICU for extended grapheme boundaries and paragraph bidi runs.
3. Within each visual bidi run, select the first font covering every codepoint
   in each grapheme. Adjacent graphemes selecting the same font remain in one
   shaping segment; RTL font segments are emitted in reverse visual order.
4. Set the FreeType pixel size, create a referenced HarfBuzz font, apply bounded
   variation coordinates, set direction, guess script/language properties, and
   shape the UTF-8 source range. Optional `liga`/`clig` disabling is supported.
5. Copy HarfBuzz glyph IDs, absolute source-byte clusters, offsets, advances,
   and cumulative positions into owned runs before destroying native buffers.

A font that covers a script's graphemes therefore shapes the whole adjacent run
rather than swapping individual codepoints. Unsupported clusters use the primary
font and produce owned missing-glyph diagnostics. HarfBuzz zero glyphs also
produce a deduplicated diagnostic.

`Text` owns all run, glyph, and diagnostic arrays and has one `destroy` operation.
Positions/advances use 26.6 units. Runs carry font identity, face index, pixel
size, and complete variation settings; `cache_key(run, glyph)` directly creates
the M05.03 cache key. No HarfBuzz/FreeType result pointer escapes a call.

## Fixtures and tests

The existing Noto Sans Mono fixture is joined by `FixtureHebrew.ttf` and
`FixtureArabic.ttf`, subset with the pinned `hb-subset` while retaining names
and layout tables. All use the SIL OFL 1.1 in `fixtures/LICENSE.txt`. Tests load
these files directly and never consult the user's fontconfig or session.

Native tests cover:

- Combining-mark glyphs sharing source cluster zero and generated cache keys.
- Mixed English/Hebrew visual bidi order, Hebrew fallback, exact byte ranges,
  descending RTL clusters, nonzero glyph IDs, and total advances.
- Arabic contextual forms versus isolated `م`, including a zero-advance mark
  sharing cluster 6 with its base.
- Missing-glyph diagnostics when no font covers Hebrew.
- Empty input, invalid UTF-8, and line-break rejection/cleanup.

The Arabic fixture produces six glyphs for five source letters because one
cluster contains a base and zero-advance mark; the test pins that mapping rather
than assuming one glyph per codepoint.

## Validation

```text
odin run make.odin -file -- text-test
    -> 14/14 native tests passed
odin run make.odin -file -- test
    -> all 250 unit tests passed
odin run make.odin -file
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> existing font/cache product lifecycle and clean shutdown still pass
odin run make.odin -file -- windows
    -> windows_amd64 product cross-build passed; shaping package is not yet
       imported by the product on either platform
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Horizontal text is implemented; vertical shaping, line breaking, bidi-control
  visualization, emoji presentation policy, and visual output are not claimed.
- Fallback uses cluster coverage, not a full Unicode font-engagement/sequence
  scoring system. Later visual fixtures may expose additional policy needs.
- Non-Linux shaping has no implementation or runtime validation.
- M05.05 should implement caret/selection hit testing from these exact runs,
  including grapheme-safe logical offsets, leading/trailing cluster edges,
  mixed bidi runs, and round-trip position/offset tests.
