# M05.07 — Huge-line bounded rendering

**Status:** done; Linux native streaming shaping and incremental measurement are
validated for bounded reads from a 10 MiB line and complete processing of a
2 MiB line. Product text drawing is not integrated yet, and non-Linux shaping
remains unimplemented.

## Streaming visible ranges

`src/text/shaping/visible_linux.odin` adds:

```text
visible_next(line, ^Measurement, fonts, options, max_bytes = 64 KiB, allocator)
    -> (Visible, Error)
```

One call shapes at most `max_bytes`, with a hard maximum of the existing 1 MiB
full-shape budget. It reads at most 4 KiB beyond that budget to determine safe
grapheme boundaries. It never validates, encodes, segments, or shapes the entire
line merely to produce the first visible chunk.

`Visible` owns its `Text` through the existing `destroy(&visible.text)` operation.
`start`/`end` are absolute source-byte offsets, `done` reports line completion,
and `segmented` is the explicit large-line fallback marker. Runs, glyph clusters,
grapheme clusters, and missing-glyph diagnostics are rebased to absolute source
offsets while x advances remain local to the returned chunk. Existing hit testing
and caret APIs therefore retain absolute source positions.

`Measurement` is caller-owned resumable state containing the next byte offset,
cumulative 26.6 advance, and whether any chunk used segmented fallback. Successful
calls advance it exactly once; errors leave it unchanged. Advance overflow and
invalid cursor/budget values are rejected. Reset the measurement when font,
shaping options, source text, or DPI generation changes.

Short lines retain the existing whole-line behavior and return `done=true` with
`segmented=false`. A first grapheme larger than the caller's byte budget returns
`.Resource_Limit` rather than splitting it or silently exceeding the budget.

## Explicit segmented fallback

Each chunk is an independent shaping paragraph. Grapheme boundaries are preserved
between chunks, but paragraph-wide bidi ordering and contextual joining across a
chunk boundary are not. Every chunk after the first, and every prefix with more
text remaining, carries `segmented=true`; a renderer must expose that fallback
rather than presenting the result as equivalent to whole-line Unicode layout.
Whole-line shaping remains the correct path for lines within the existing budget.

This is the deliberate large-line policy for M05.07, not a claim of correct
paragraph-wide bidi or joining for arbitrarily segmented huge lines.

## Bounded algorithmic work

The first streaming test exposed an existing quadratic font-fallback path: each
grapheme scanned every codepoint in the chunk. A bounded 64 KiB chunk could still
require billions of checks, and the initial native test was stopped after spinning
at 100% CPU.

`codepoints_for_grapheme` now uses binary search and iterates only codepoints in
that grapheme. Cluster-range discovery in `build_clusters` also uses binary
searches instead of rescanning all preceding graphemes for every font segment.
Missing-glyph diagnostics are capped at 64 per shaped chunk, which also bounds
their deduplication work. With these fixes the complete 25-test native suite runs
in about 0.75 seconds in the recorded debug test run.

## Tests

Four streaming tests cover:

- A real 10 MiB ASCII line: the first two calls each shape at most 4 KiB, preserve
  absolute ranges, and accumulate advances.
- A 2 MiB + 17 byte line processed to completion in at most 40 calls, with every
  call bounded to 64 KiB and cumulative width checked after every chunk.
- Combining marks and a woman-technologist ZWJ emoji at forced small chunk
  boundaries: exact grapheme ranges and total advance match whole-line shaping.
- Segmented mixed-bidi fallback, absolute caret/hit offsets, invalid cursors and
  budgets, oversized graphemes, invalid UTF-8, and short/empty non-fallback lines.

A separate regression test pins the 64-entry missing-glyph diagnostic cap.

## Validation

```text
timeout 90s odin run make.odin -file -- text-test
    -> 25/25 native text tests passed (about 0.75 s)
odin run make.odin -file -- test
    -> all 256 unit tests passed
odin run make.odin -file
    -> Linux debug product build passed
odin run make.odin -file -- windows
    -> windows_amd64 product cross-build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=12 \
    HAMMER_TEST_DPI_SCALES=1,1.25,1.5,2,1.5,1.25,1 \
    HAMMER_RENDER_PROBE=4 HAMMER_LOG= ./build/hammer
    -> DPI/cache transitions, exact render colors, clean shutdown
git diff --check
    -> no whitespace errors
```

The timeout is an external safety bound, not a performance threshold. No release
wall-clock budget or cross-platform runtime result is claimed.

## Limits and next task

- Product drawing, horizontal-scroll integration, and retained measurement caches
  are not implemented; the native API supplies the bounded operations those owners
  need without adding a product stub.
- Huge mixed-script visual behavior, including presentation of the segmented
  fallback, needs fixtures. Non-Linux streaming shaping is not implemented.
- M05.08 should add mixed-script/DPI visual fixtures, including combining marks,
  emoji, CJK, RTL text, fractional scales, and the explicit segmented-line state.
