# M06-Detour-3 — Windows font discovery and rendering

**Status:** done on native Windows with the Sokol GL backend. DirectWrite
Discovery, shaping, rasterization, fallback, and product rendering were exercised
on real Windows. Linux type-checks; its native tests were not rerun.

## Implementation

`src/text/directwrite` contains narrow bindings to the stable DirectWrite base
COM interfaces used by Hammer. Signatures and vtable positions were checked
against the installed Windows 10 SDK. `src/text/icu` now also links the
unversioned Windows system ICU exports used for grapheme segmentation and bidi;
the pinned Linux ICU path is unchanged.

`src/text/fonts/native_windows.odin` resolves configured families through the
system font collection. Generic `monospace` maps to Consolas, sans roles to
Segoe UI, serif to Cambria, and emoji to Segoe UI Emoji. Explicit font paths are
analyzed and opened without installing them. Local font-file references provide
path and face-index metadata. Missing required roles fail initialization and
release all partially acquired COM objects.

Fallback searches at most 4096 system families and retains the existing limits
of fourteen faces and sixty-four cached misses. Each face owns its DirectWrite
face, wrapper, path, and family strings. The factory, collection, and analyzer
are owned by the set and released after every face.

`src/text/shaping/shape_windows.odin` uses call-scoped DirectWrite script
analysis, ICU graphemes and bidi, bounded glyph-buffer growth, and the existing
26.6 positioned-run contract. Substituted glyphs without direct character map
entries inherit the neighboring cluster. RTL glyph results are reversed into
visual grapheme order. Ligature features can be enabled or disabled.

`src/text/glyphcache/rasterize_windows.odin` creates bounded DirectWrite alpha
textures, converts subpixel coverage to grayscale, and supplies atlas metrics.
The existing product renderer, visible-line shaping, and hit-testing now build
on both Linux and Windows; only pixel sizing and ascent remain platform-specific.
Unsupported platforms retain explicit stubs.

## Tests

Six native tests cover:

- System discovery, generic aliases, real file metadata, and glyph lookup.
- Explicit fixture loading, codepoint fallback, hit/miss caching, and invalid
  Unicode scalars.
- Missing-family and explicit-path cleanup.
- Combining marks, shaped clusters, ligatures, and nonempty rasterized pixels.
- Hebrew and Arabic visual grapheme order with real fallback faces.
- Enabled versus disabled DirectWrite ligature features.

The product harness starts Hammer with a sandboxed UTF-8 sample and captures only
its owned HWND using `PrintWindow`; it does not read unrelated screen contents.
It checks minimum visible ink on ASCII/combining/box, Hebrew, Arabic, Devanagari,
math/currency, and emoji/ZWJ lines, rejects logged text-rendering errors, waits
for clean autoquit, and removes the sandbox. An optional screenshot was inspected
and showed all six lines.

## Validation

Using native Odin `dev-2026-11-nightly:ece728c` on Windows:

```text
odin run make.odin -file -- windows-text-test
    -> all 6 native tests passed with allocator tracking; debug build passed;
       all 6 product lines met the ink threshold and exited cleanly
odin run make.odin -file -- test
    -> all 324 core unit tests passed
odin run make.odin -file -- --release
python tests/integration/text_windows/product_harness.py --binary build/hammer.exe
    -> release build and all 6 product rendering checks passed
odin check src -target:linux_amd64 -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true -vet
    -> Linux target type-check passed
odin check make.odin -file -vet -strict-style
python -c "import ast, pathlib; ast.parse(pathlib.Path('tests/integration/text_windows/product_harness.py').read_text())"
git diff --check
    -> all checks passed
```

## Limits and next task

- Windows emoji currently render as grayscale coverage, not color glyphs.
- Variable-font coordinates and custom font collections are not implemented.
- Only the Windows GL backend and the current device were validated. D3D11,
  other Windows versions, and native Linux runtime behavior were not exercised.
- Next is M07.01: implement columns/window layout and dragging, with core layout
  tests and real pointer behavior validation on the supported platform paths.
