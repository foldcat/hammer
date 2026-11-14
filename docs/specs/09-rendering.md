# 9. Rendering, Unicode, fonts, and DPI

## 9.1 Rendering architecture

Use custom editor rendering on Sokol.

Recommended layers:

```text
Background
Git gutter/change marks
Syntax styles
Search matches
Selection
Text glyphs
Caret
Tag controls
Transient overlays
```

Keep layout state retained, while allowing the drawing code to have an immediate-mode feel.

Do not use a generic multiline text widget as the final editor implementation.

## 9.2 Shape visible text

Pipeline:

```text
Rope range
 -> line segmentation
 -> script/bidi runs
 -> font fallback
 -> HarfBuzz shaping
 -> glyph lookup/rasterization
 -> positioned glyph draw commands
```

Use one shaped representation for:

- Rendering.
- Hit testing.
- Selection geometry.
- Cursor positioning.

Otherwise clicking and visual text will disagree.

## 9.3 Font handling

Support:

- Family-name lookup.
- Explicit font file paths.
- Ordered fallback families.
- Separate body/tag/console font roles if desired.
- Font size in points.
- Configurable line height.
- Optional ligatures.
- Missing-glyph diagnostics.

Fallback must work by appropriate shaping cluster/run boundaries, not by swapping individual code points indiscriminately.

## 9.4 Glyph cache

Cache keys should include:

```text
font identity
face index
variation settings
glyph ID
pixel size
render mode
```

Use bounded atlas pages with eviction.

Do not let every zoom level or monitor transition permanently add another complete font atlas.

## 9.5 Unicode behavior

Required:

- Combining marks.
- Extended grapheme sequences.
- CJK.
- Emoji sequences.
- Correct selection boundaries.
- Correct shaping for scripts that require it.
- Bidi policy documented and tested.
- IME preedit and commit handling.

For source code, consider visible indicators for:

- Bidi control characters.
- Nonprinting characters.
- Suspicious whitespace.

These should not alter the underlying file.

## 9.6 DPI model

Store layout measurements in logical units.

Convert to physical pixels using the current window/monitor scale.

For a point-based font size:

```text
logical pixels ≈ points × 96 / 72
physical pixels = logical pixels × scale
```

The exact platform integration must account for whether event coordinates and framebuffer sizes are already scaled.

Never apply DPI twice.

On DPI changes:

1. Update scale.
2. Recompute font pixel sizes.
3. Invalidate relevant glyph/layout caches.
4. Preserve logical layout proportions.
5. Redraw.

Test:

- 100%, 125%, 150%, 200%.
- Moving between mixed-DPI monitors.
- Resizing.
- Touchpad scrolling.
- Hit-testing at fractional scale.

## 9.7 Huge lines

A single ten-megabyte line must not freeze rendering.

Use:

- Bounded visible-range processing.
- Chunked/segmented measurement.
- Safe shaping boundaries.
- Incremental width measurement.
- Explicit large-line fallback behavior.

Never shape an entire enormous line synchronously merely to paint its visible beginning.
