# Hotfix: tag text clipped at the bottom

**Status:** done on Linux/X11; shared render code, Windows source type-check
passes. This was a requested hotfix and does not replace the active M07.04 task.

## Root cause

Two related defects made tag text clip at the bottom of its strip:

1. **Global tag strip was shorter than the others.** `src/render.odin` inset
   the global tag by `pad` on all four sides, reducing its height from
   `tag_height` (20 logical px at the default 12 pt font) to 16, while column
   and window tags kept the full 20 px. The global tag's content rectangle and
   scissor were therefore 16 px tall, cutting the baseline (and the bottom of
   every glyph) off below y=18. Column and window tags were not vertically
   inset, so they rendered the full strip.

2. **Tag baseline left no room for descenders.** `text_render_document` placed
   every tag's baseline at `rect.y + TEXT_PADDING + ascent`. With a fixed 4 px
   top padding and the font's real ascender, the descenders (and, for round
   glyphs, part of the body) fell below the 20 px strip and were clipped by the
   tag scissor. This affected every tag once the global tag was corrected to the
   same height.

## Fix

`src/render.odin` now keeps the full `tag_height` for the global tag content
rectangle (insetting only x/y/width, not height), matching column and window
tags. Both `render_frame` and `editor_active_text_rect` were corrected so
rendering and caret/hit-test geometry stay consistent.

`src/text_render_native.odin` now centers a tag's single line vertically in its
strip using the font's real ascender and descender:

```odin
baseline = (line_top + max(0, (line_height - (ascent + descent) / scale) / 2)) * scale + ascent
```

The padding is clamped to zero, so a font taller than the strip overflows the
descender rather than pushing the cap height off the top. Body text keeps its
existing `TEXT_PADDING`-based baseline.

To obtain the descender, `native_descender` was added to
`src/text/fonts/native_linux.odin` (FreeType, negating the negative `descender`
metric) and `src/text/fonts/native_windows.odin` (DirectWrite, whose `descent`
is already positive). Both return the positive descent in 26.6 format, mirroring
`native_ascender`.

No layout or transaction code changed.

## Regression coverage

`tests/integration/tags/x11_harness.py` now captures the full global tag strip
(y in `[2, 22)` instead of `[2, 18)`) and asserts that the strip's bottom edge
(pixel `(300, 21)`, away from text) still paints the tag background `#262626`.
A regression to the 16 px strip would leave that pixel at the clear/body color.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin run make.odin -file -- test
    -> all core unit tests passed, allocator tracking clean
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed, including the new
       "global tag strip is full height" check
odin run make.odin -file -- view-test --no-config
    -> all four independent-view checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

A pixel readback confirmed the global tag text now sits vertically centered in
its strip with the ascender and descender both inside the strip (previously the
baseline was clipped at the strip bottom).

## Not validated / pre-existing

Native Windows/Wine runtime (cross-build type-checks only, consistent with the
pre-existing Windows block). Real-desktop visual review not performed.

`odin run make.odin -file -- layout-test --no-config` fails at
"moving the active window did not change rendered pixels". This failure is
pre-existing and unrelated to this change: it reproduces identically with the
render fix reverted (verified via `git stash`). It is a separate M07.01 layout
test issue, not part of this hotfix.
