# M07.11 — Per-view line-number gutter display

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Per-view state and shared geometry

Each `core/view.View` owns a `line_numbers` flag, enabled by default when a view
is added. Independent views can therefore use different gutter state without
changing their shared buffer.

`src/gutter_ui.odin` splits each body into scrollbar, gutter, and text content.
Rendering, mouse hit-testing, vertical/horizontal scrolling, and scrollbar
interaction all use this same geometry helper. Tags never receive gutters.
Disabled or unmeasurable gutters collapse to zero width, and no separator is
painted in that case.

The width uses the current body font's measured zero advance, document logical
line count, and logical padding. A two-digit minimum avoids layout jumps for
small documents; 100-line and larger documents widen as required. Measurements
remain logical and are recomputed with current font/DPI state.

## Rendering

`text_render_native.odin` draws right-aligned, one-based logical line numbers in
muted gray `#808080`, with a dark separator at the content edge. Numbers share
the body font, baseline, glyph cache, bounded glyph budget, and per-rectangle
scissoring. Temporary number strings and shaped data live only in the frame
arena.

Numbers are emitted only when the current logical line starts at visual row
zero. Soft-wrapped continuation rows remain blank. Scrolling partway through a
wrapped line hides that line's number until its first row is visible again;
following logical lines retain their correct numbers. Truncate mode displays
one number per visible row.

Existing body glyph colors are passed explicitly through the same collector, so
ordinary and color-emoji rendering retain their prior behavior. Native stub
signatures remain aligned on unsupported platforms.

## Regression coverage

The view unit suite now covers independent gutter enablement and digit counts,
including the two-digit minimum and 100/1000-line boundaries. The existing X11
harness coordinates were moved into the text content rectangle without changing
their exact edit/command assertions.

`scroll-test` now performs 15 checks. Soft and truncate scenarios verify muted
number pixels and logical-line numbering; soft continuation rows must contain
zero number pixels. Both modes also verify exact source-byte insertion after
scrolling and gutter presence after a real resize. A separate process exercises
runtime DPI transitions through 200% and checks the scaled gutter pixels.

The shared X11 image helper now calls `XGetGeometry` before `XGetImage`, fixing
capture after non-800×600 resizes rather than relying on fixed dimensions.

## Validation

```text
odin run make.odin -file -- scroll-test
    -> all 15 viewport/scrollbar/gutter checks passed, including resize and 200% DPI
odin run make.odin -file -- wrap-test
    -> all 7 soft/truncate checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord and ten cut/undo stress checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin run make.odin -file -- view-test --no-config
    -> all independent-buffer/view checks passed
odin run make.odin -file -- look-test --no-config
    -> all Look/file-opening checks passed
odin run make.odin -file -- directory-test --no-config
    -> all directory/error checks passed
odin run make.odin -file -- layout-test --no-config
    -> all layout checks passed
odin run make.odin -file -- compatibility-test --no-config
    -> all 7 compatibility stages passed
odin run make.odin -file -- test
    -> all 370 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 40 native text tests and 4 visual golden hashes passed
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop visual review was performed. Runtime
DPI behavior was validated with the product's deterministic scale hook on
Linux/X11, not by moving a window between physical monitors.

## Next task

M07.detour-2 should change the cursor icon only while hovering window/column
resize boxes, preserving existing drag behavior and adding focused validation.
