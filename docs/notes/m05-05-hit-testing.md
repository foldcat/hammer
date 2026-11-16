# M05.05 — Selection/caret hit testing from shaped runs

**Status:** done; Linux native shaped-run hit testing and selection geometry are
validated. The product does not yet draw shaped text or route mouse input through
these APIs.

## Grapheme layout and ownership

Each shaping `Run` now owns a visual-order `clusters` array alongside its glyphs.
Each `Cluster` records one extended grapheme's absolute source-byte range and its
26.6 x/advance. HarfBuzz glyphs sharing a cluster are measured as one advance
group. Multiple groups inside one ICU grapheme accumulate their advances. If a
ligature subsumes multiple graphemes, its advance is subdivided proportionally
with integer endpoints, preserving every grapheme boundary without splitting
the glyph itself.

`Text.destroy` releases both glyph and cluster arrays for every run. Hit testing
and caret positioning allocate nothing and borrow `Text` immutably. Selection
spans use the caller's allocator and must be released with `delete`.

## Hit-testing and selection APIs

`src/text/shaping/hit_test.odin` provides:

- `hit_test(text, logical_x, scale = 1) -> (Caret, bool)`: choose the nearest
  visual cluster half, returning an absolute source byte offset,
  leading/trailing edge, and logical caret x. Coordinates before/after the line
  clamp to its visual ends; empty text maps to offset zero.
- `caret_position(text, offset, edge, scale = 1) -> (logical_x, bool)`: map a
  grapheme boundary back to its logical visual position. Bytes inside UTF-8
  codepoints or graphemes are rejected. Leading/trailing edges distinguish the
  two positions at mixed-bidi boundaries; text start/end accept either edge.
- `selection_spans(text, start, end, scale = 1, allocator)`: return visual-order
  logical x spans for either source selection direction. Adjacent selected
  graphemes are coalesced, while disjoint bidi ranges remain separate. Invalid
  endpoints and malformed cluster layouts return `.Invalid_Input` without
  partial output.

For LTR clusters, leading is the left edge and trailing the right; RTL reverses
that mapping. Layout validation checks source coverage, visual advances, and run
totals before returning coordinates. Non-finite hit-test x values are rejected.

Shaped advances use the physical pixel size needed by glyph rasterization. The
`scale` argument is the physical/logical ratio: hit testing multiplies logical x
by scale, while caret and selection geometry divide physical advances by scale.
Thus DPI is applied exactly once. Scales must be finite and in `(0, 32]`.

## Tests

Six native tests were added in `tests/integration/textdeps/shaping_test.odin`:

- Combining `A + acute` and a woman-technologist ZWJ emoji expose only grapheme
  byte boundaries, with hit/position round trips.
- A synthetic one-glyph RTL ligature with two graphemes verifies proportional
  caret positions and selection halves. The bundled font fixtures do not produce
  a single-glyph ligature, so native HarfBuzz production of that exact case is
  not claimed as tested.
- Hebrew verifies visual-order source ranges, leading/trailing edges, and
  round trips at every grapheme.
- Mixed English/Hebrew verifies distinct affinities at the bidi boundary,
  disjoint partial selection spans, reversed full selection, and invalid byte
  rejection.
- Empty text verifies hit, caret, and empty-selection behavior.
- Fractional 125% and 200% scales verify caret/hit/selection round trips, and
  zero scale is rejected by all three APIs.

## Validation

```text
odin run make.odin -file -- text-test
    -> exact dependency pins accepted; 20/20 native tests passed
odin run make.odin -file -- test
    -> all 250 unit tests passed
odin run make.odin -file
    -> debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> 10-frame Linux/X11 lifecycle smoke passed
odin run make.odin -file -- windows
    -> windows_amd64 product cross-build passed; shaping is not imported by
       the product and Windows shaping/hit testing was not runtime-tested
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Selection rectangles are horizontal x spans for one shaped line; line layout,
  clipping, drawing, and mouse-event integration remain later rendering work.
- Ligature subdivision is an advance-based caret policy, not glyph ink hit
  testing. The synthetic fixture does not validate a native single-glyph
  ligature end to end.
- Non-Linux shaping and hit-testing runtime behavior remain unvalidated.
- M05.06 should invalidate font/layout/glyph state on DPI changes while
  preserving logical layout proportions and avoiding double scaling.
