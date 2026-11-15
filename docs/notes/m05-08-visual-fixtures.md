# M05.08 — Mixed-script/DPI visual fixtures

**Status:** done; deterministic CPU visual fixtures are validated on Linux with
pinned libraries at 100%, 125%, 150%, and 200%. Product-window text integration,
non-Linux rendering, and real mixed-monitor hardware remain outside this
validation.

## Bundled fonts

Two small fonts join the existing Latin, Hebrew, and Arabic subsets:

- `FixtureCJK.otf`: Noto Sans CJK JP 2.001, subset to `漢字界` (3,444 bytes).
- `FixtureEmoji.ttf`: Noto Emoji Regular 3.003, subset to woman, laptop, and ZWJ
  (2,676 bytes). This is deliberately the monochrome font; color emoji rendering
  is not claimed.

They were generated with the pinned HarfBuzz 12.3.2 tools:

```text
hb-subset /usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
    --text='漢字界' --output-file=FixtureCJK.otf
hb-subset /usr/share/fonts/noto-emoji/NotoEmoji-Regular.ttf \
    --text='👩💻‍' --output-file=FixtureEmoji.ttf
```

The system font paths are generation inputs only. Tests load the bundled files
directly and never discover the user's fonts. `LICENSE_CJK.txt` and
`LICENSE_EMOJI.txt` carry the copyright notices and SIL OFL 1.1 terms.

## CPU visual harness

`tests/integration/textdeps/visual_test.odin` shapes each line with the normal
ICU/HarfBuzz pipeline, fetches every glyph through the normal cache key and
FreeType rasterizer, and composites atlas coverage into a bounded grayscale
canvas. Glyph positions use the shaped 26.6 positions and atlas bitmap bearings.
Selection and caret geometry comes from the same shaped runs and is painted
behind/around the glyphs. Coverage uses source-over blending so antialiasing
remains visible over selection and caret backgrounds.

Each canvas contains:

1. `A` + acute and CJK text, with an explicit CJK fallback-face assertion.
2. A woman-technologist ZWJ emoji, with an explicit emoji fallback-face assertion.
3. Mixed English/Hebrew with a partial selection and caret.
4. Arabic contextual forms.
5. RTL/bidi embedding controls.
6. A bounded streaming prefix with a visible segmented-fallback marker.

The harness checks nonempty text ink, no missing glyphs for the primary script
fixtures, fallback face IDs, selection/caret validity, segmented status, and
distinct hashes across DPI. These structural assertions prevent a blank or
wrong-font image from passing merely because a golden was regenerated.

## Golden images and DPI

The four checked-in PGM files are binary P5 images. Canvas geometry begins in
logical units and is scaled once; font physical sizes are 16, 20, 24, and 32 px.
Selection/caret logical coordinates are converted back to physical pixels once.

| Scale | Canvas | FNV-1a 64 hash |
| ----- | ------ | -------------- |
| 100% | 320x192 | `3151400300749b28` |
| 125% | 400x240 | `81fcbfa021c0733a` |
| 150% | 480x288 | `ece4a599f9d40050` |
| 200% | 640x384 | `f1fe58bd8c883bdc` |

Normal tests read the goldens and compare every byte, including dimensions and
pixels. Exact comparison is appropriate for this CPU-only fixture with pinned
FreeType/HarfBuzz versions; it is not a claim that GPU screenshots are identical
across drivers.

The images were also converted to PNG and visually inspected at all four scales.
The final source-over versions were rechecked at 100% and 200%. Temporary PNG and
PGM generation outputs were removed after the reviewed PGM files were installed.

For intentional rendering changes, an explicit maintainer update can write new
candidates outside the fixture tree:

```text
HAMMER_WRITE_GOLDEN=build/golden odin run make.odin -file -- text-test
```

Review those images before installing them as goldens. Without this environment
variable, the visual test performs no fixture writes.

## Validation

```text
timeout 90s odin run make.odin -file -- text-test
    -> 26/26 native tests passed; all four golden hashes matched
odin run make.odin -file -- test
    -> all 256 unit tests passed
odin run make.odin -file
    -> Linux debug product build passed
odin run make.odin -file -- windows
    -> windows_amd64 product cross-build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=12 \
    HAMMER_TEST_DPI_SCALES=1,1.25,1.5,2,1.5,1.25,1 \
    HAMMER_RENDER_PROBE=4 HAMMER_LOG= ./build/hammer
    -> existing product DPI/render behavior and clean shutdown passed
git diff --check
    -> no whitespace errors
```

## M05 acceptance and limits

- Combining and emoji fixtures expose only valid grapheme caret boundaries;
  selection/caret geometry is visible in the same rendered output as the glyphs.
- Fractional-DPI fixtures preserve logical geometry while rasterizing at the new
  physical sizes. Actual mixed-monitor hardware was not available.
- Huge-line processing is bounded and its segmented state has a visual marker.
- The visual harness is a test renderer, not product-window text drawing.
  Non-Linux shaping/rasterization, color emoji, GPU screenshot portability, and
  real desktop mixed-DPI movement remain unvalidated.
- M06.01 should implement movement and selection actions using the existing
  grapheme-safe offsets and visual affinity policy, with transaction and undo
  integration where edits are involved.
