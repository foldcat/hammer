# M05.01 — Bind and pin font/shaping/Unicode libraries

**Status:** done; Linux native API and regression tests pass. Product
rendering does not use these packages yet.

## Dependency decision

Use FreeType for font loading/rasterization, HarfBuzz for shaping, and ICU4C
for the complete Unicode strategy (grapheme/word/line boundaries, bidi, and
character properties). HarfBuzz is not treated as a segmentation or bidi
implementation.

| Component | Exact pin | Upstream source | License |
| --- | --- | --- | --- |
| FreeType | 2.15.0; pkg-config/libtool version 26.7.20 | https://github.com/freetype/freetype/tree/VER-2-15-0 | FreeType License (chosen from the FTL/GPLv2 dual license) |
| HarfBuzz | 12.3.2 | https://github.com/harfbuzz/harfbuzz/tree/12.3.2 | Old MIT |
| ICU4C | 78.3; Unicode data 17.0.0 | https://github.com/unicode-org/icu/tree/maint/maint-78 | Unicode-3.0 and bundled third-party notices |
| shaderc/glslc | shaderc-2026.3 | https://github.com/google/shaderc/tree/v2026.3 | Apache-2.0 |

These are dynamically linked system libraries, not copied sources or
binaries. `odin run make.odin -file -- text-test` uses `pkg-config
--exact-version` and `glslc --version` to reject missing or different
versions before building the tests. Runtime tests independently verify the
library and Unicode-data versions. No third-party Odin binding was imported;
the narrow declarations were audited directly against the installed pinned C
headers.

## Bindings and ownership

- `src/text/freetype/freetype.odin`: library/face lifecycle, file and borrowed
  memory faces, pixel sizing, character/glyph loading, rendering, and the
  public face/size/glyph/bitmap records needed by M05.02–M05.04. Memory-face
  bytes must outlive `FT_Done_Face`; faces are destroyed before their library.
- `src/text/harfbuzz/harfbuzz.odin`: file blobs, faces/fonts, hb-ft referenced
  fonts, UTF-8/UTF-16 buffers, segment properties, shaping, features, and
  glyph info/position results. Glyph arrays remain buffer-owned. hb-ft fonts
  are destroyed before their referenced FreeType face. The empty-font
  singleton used by the test is borrowed and never destroyed.
- `src/text/icu/icu.odin`: ICU and Unicode version queries, character/word/
  line/sentence iterator types, grapheme and word iteration, bidi paragraph
  setup/direction/run counts/logical-visual maps, general categories, and
  binary properties. Native objects use their matching ICU close functions.
  This machine's ICU build disables symbol renaming, so the declarations use
  unadorned symbols such as `u_getVersion`, not `u_getVersion_78`; a standard
  renamed ICU build requires a separate audited binding variant.

FreeType/HarfBuzz public-record size and offset assertions pin the Linux
LP64 ABI. A C probe compiled directly against the headers confirmed the same
values. Unsafe surface is limited to foreign pointers, C integer widths,
borrowed arrays, and these explicit records; no foreign memory is freed by an
Odin allocator.

## Tests

`tests/integration/textdeps/textdeps_test.odin` makes real native calls:

1. FreeType init/version/destroy and rejection of an invalid in-memory font.
2. HarfBuzz exact version, UTF-8 combining-mark input, guessed properties,
   empty-font shaping, cluster order, and glyph position/result layouts.
3. ICU 78.3/Unicode 17 versions; extended grapheme boundaries for a combining
   sequence and a woman-technologist ZWJ emoji; word boundaries.
4. ICU mixed English/Hebrew bidi direction, run count, logical/visual mapping,
   and alphabetic/whitespace/bidi-control/general-category properties.

The fixtures are fixed stack arrays. Tests do not discover fonts, read user
files, touch a session, or allocate through the disabled product allocator.

## Validation

```text
odin run make.odin -file -- text-test
    -> exact pkg-config/glslc pins accepted; 4/4 tests passed
cc $(pkg-config --cflags freetype2 harfbuzz) build/m05_01_abi.c -o build/m05_01_abi
build/m05_01_abi
    -> C sizes/offsets matched the new compile-time Odin ABI assertions
odin run make.odin -file -- test
    -> all 242 existing unit tests passed
odin run make.odin -file
    -> normal debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> 10-frame window/render/shutdown smoke test exited 0
```

The temporary C ABI probe source and executable were removed after the
layout comparison.

## Limits and follow-up

- Only Linux is bound and tested. Windows, macOS, renamed-symbol ICU builds,
  and non-LP64 FreeType targets are not implemented.
- No valid font file was loaded or rasterized, no hb-ft font was shaped, and
  no visual output was produced; those belong to M05.02–M05.04. HarfBuzz's
  empty-font path is an API/ABI smoke test, not proof of correct script shaping.
- glslc is version-pinned and checked, but the current embedded GL shader path
  is unchanged; portable generated shader variants remain renderer work.
- M05.02 should implement isolated font discovery and role selection behind
  these bindings, with explicit font-file ownership and failure paths.
