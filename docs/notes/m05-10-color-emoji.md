# M05.10 — Color emoji and full emoji-sequence rendering

**Status:** done on Linux/X11. Native shaping, fixed-strike color rasterization,
RGBA atlas/upload, product fallback, grapheme deletion, and undo are validated.
Non-Linux shaping/rasterization and non-Noto color-font formats remain
unvalidated.

## Sequence shaping and fallback

`src/text/shaping` now recognizes emoji-presentation clusters through ICU, ZWJ,
and VS16. A color-capable face that covers the complete grapheme is preferred for
those clusters; ordinary ordered font fallback still applies otherwise. This
fixes the case where a monochrome body font covers `❤` and VS16 and previously
won before the color face, producing missing glyphs. Variation selectors are
shaping controls and no longer incorrectly require independent cmap glyphs or
produce missing-glyph diagnostics.

Color runs carry `glyphcache.Render_Mode.Color` into the existing cache key. The
same positioned runs drive drawing, caret positions, selection geometry, and hit
testing, so one emoji sequence remains one source grapheme even though it may
contain many UTF-8 codepoints.

The product adds an optional `fonts.Role.Emoji`, discovered as `Noto Color Emoji`
then generic `emoji`, independently of an explicit body `font_path`. Missing emoji
faces leave ordinary text available. Rendering and hit testing share one bounded
body/emoji/dynamic-fallback font list; stable face IDs key the glyph cache.

## Native color rasterization

FreeType color loading uses `FT_LOAD_COLOR`. Scalable fonts use the requested
pixel size. Fixed-strike fonts such as Noto Color Emoji select the nearest native
strike (109 px in the validated font), while HarfBuzz is explicitly scaled to the
requested 26.6 advance size. Strike `y_ppem` is converted from 26.6 units before
calling `FT_Set_Pixel_Sizes`.

`src/text/glyphcache/rasterize_linux.odin` converts premultiplied BGRA to RGBA and
bilinearly resamples the bitmap, bearings, and metrics to the requested size. The
resampled allocation is owned and released after the cache copies it. Dimensions,
native bitmap size, allocation, pitch, and pixel format are validated before use.

Cache pages now have an explicit `Alpha` or `RGBA` format. Different formats never
share a page, page strides include their channel count, and reset, LRU eviction,
and replacement preserve each page's format lifecycle. GPU upload maps these to
R8 and RGBA8 respectively.

The text shader outputs premultiplied alpha for both paths and uses
`ONE`/`ONE_MINUS_SRC_ALPHA` blending. Alpha glyphs retain their previous body-color
appearance; RGBA glyphs retain native colors instead of being tinted.

## Fixture and coverage

`FixtureColorEmoji.ttf` is a 101 KiB Noto Color Emoji subset generated with pinned
`hb-subset` 12.3.2. It includes woman-technologist, thumbs-up with a skin-tone
modifier, family, heart with VS16, the Canadian flag, and a keycap sequence. The
existing `LICENSE_EMOJI.txt` now names both Noto Emoji products. Tests load only
the bundled fixture, not user font directories.

Native tests cover:

- one HarfBuzz glyph and one grapheme per ZWJ, modifier, family, VS16, regional-
  indicator flag, and keycap sequence;
- exact source-byte ranges, distinct glyph IDs, advances, and caret/selection
  validity;
- requested sizes 16, 20, 24, and 32 physical pixels with monotonically increasing
  advances and bitmap dimensions;
- real RGBA pixels, non-gray color where the font provides it, premultiplied
  channels, optional font-role discovery, and separate Alpha/RGBA cache pages.

`make.odin -- emoji-test` runs a real X11 product scenario in an isolated Xvfb
session. It pastes all six sequences through the independent clipboard peer,
checks native colored pixels, round-trips every byte through external clipboard
reads, deletes all eight graphemes with ordinary Backspace, checks each remaining
payload, and undoes all nine transactions back to the initial document. The
validated run sampled 942 colored pixels. Logs must contain the emoji face and no
render-text error.

## Validation

Using pinned Odin `dev-2026-11` and the repository's native text pins:

```text
odin run make.odin -file -- text-test
    -> all 33 native text tests passed; four existing visual goldens matched
odin test tests/unit/glyphcache -vet -collection:hammer=src
    -> 7/7 passed, allocator tracking clean
odin run make.odin -file -- emoji-test
    -> colored rendering, all sequence round-trips, grapheme deletion, and undo passed
odin run make.odin -file -- test
    -> all 302 core unit tests passed, allocator tracking clean
odin run make.odin -file -- typing-test --no-config
    -> all existing X11 typing, modified-Backspace, mouse, and clipboard checks passed
odin run make.odin -file -- ligature-test
    -> enabled/disabled product ligature rendering still passed
odin run make.odin -file -- windows --no-config
    -> Windows product cross-build passed; no Windows shaping/runtime claim
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("tests/integration/emoji/x11_harness.py").read_text())'
    -> harness syntax check passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Validation covers Noto's CBDT/CBLC bitmap path through FreeType. COLRv0 is
  supported by the same FreeType color-load API but not separately fixture-tested;
  COLRv1 and SVG color fonts are not claimed.
- Regional indicators, keycaps, VS16, modifiers, and ZWJ sequences are covered.
  Tag-sequence flags and every platform's emoji presentation policy are not
  independently fixture-tested.
- Non-Linux shaping, color rasterization, product rendering, and real mixed-DPI
  monitor movement remain unvalidated.
- M05.09 and M05.10 complete the reopened M05 follow-ups. The next task is M06.12,
  newline indentation inheritance.
