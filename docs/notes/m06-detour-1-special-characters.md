# M06-Detour-1 — Special-character rendering

**Status:** done on Linux/X11. Native shaping/rasterization and real product
rendering are validated. Windows cross-builds; non-Linux shaping and runtime
rendering remain unvalidated.

## Root causes and fixes

Two independent problems prevented reliable special-character rendering:

1. The product supplied only its selected body face and optional color-emoji
   face to HarfBuzz. Fontconfig was not queried when those faces lacked a
   character, so complex scripts and less common symbols became missing glyphs.
2. `build_clusters` required every HarfBuzz glyph-group cluster to equal an ICU
   grapheme's first byte. That is not valid for scripts such as Devanagari. In
   `नमस्ते`, ICU keeps `स्ते` together while HarfBuzz returns groups at byte
   offsets 2 and 4. Hammer rejected the entire shaped line.

`src/text/fonts` now performs on-demand fontconfig charset matches. A `Set`
owns up to fourteen fallback faces in fixed storage, plus sixty-four cached
unsupported-codepoint misses. Every face has a stable glyph-cache identity.
Faces, paths, families, native patterns, and charsets have matching cleanup;
fallback faces are destroyed before their shared FreeType library.

`src/fonts_linux.odin` retries visible-line shaping only when a missing glyph
led to a newly loaded face. Rendering and mouse hit testing use this same path.
The complete shaping list remains bounded at sixteen faces: body, optional
emoji, and at most fourteen fallbacks. Unsupported text retains the existing
missing-glyph diagnostics rather than looping or failing the buffer edit.

`src/text/shaping` now maps HarfBuzz clusters to the containing ICU grapheme,
not only its starting byte. Advances from multiple groups in one grapheme are
accumulated. A group spanning multiple graphemes still has its advance divided
with integer endpoints. Source ranges remain in visual order, and the final
cluster advances must equal the shaped run advance. Existing bidi, ligature,
selection, and visual golden behavior is unchanged.

## Coverage

Small SIL-OFL Noto subsets make native tests independent of installed fonts.
The tests exercise real HarfBuzz output and FreeType rasterization for:

- The requested combining marks, Zalgo samples, and stacked vowels, including
  zero-advance marks and grapheme-safe caret/selection boundaries.
- Devanagari conjuncts, Tamil, Thai, and Khmer, with exact grapheme counts.
- Mixed English/Hebrew/Arabic/number bidi runs.
- Box drawing, block elements, Braille, math, currency, and technical symbols.
- Existing emoji ZWJ, modifier, family, VS16, flag, and keycap sequences.

`unicode-test` pastes twelve lines into the real X11 product, checks visible ink
on every line, verifies complex-script and symbol fallback faces were loaded,
round-trips the complete UTF-8 payload through an independent clipboard owner,
and rejects render errors. An optional `--screenshot` argument captures the
actual window; the final image was inspected for the previous tofu-box failure.
The separate `emoji-test` retains colored-pixel and grapheme-deletion checks.

## Validation

Using pinned Odin `dev-2026-11` and the repository's native text pins:

```text
odin run make.odin -file -- text-test
    -> all 38 native text tests passed; four visual goldens matched
odin run make.odin -file -- unicode-test
    -> all twelve lines rendered; fallback and byte-exact clipboard checks passed
xvfb-run -a python3 tests/integration/unicode/x11_harness.py \
       --binary build/hammer --clipboard-peer build/clipboard_spike \
       --screenshot build/unicode.png
    -> passed; screenshot inspected
odin run make.odin -file -- emoji-test
    -> color emoji, sequence round-trips, grapheme deletion, and undo passed
odin run make.odin -file -- typing-test --no-config
    -> typing, mouse, clipboard, modified Backspace, and close checks passed
odin run make.odin -file -- ligature-test
    -> enabled/disabled native ligature rendering passed
odin run make.odin -file -- test
    -> all 302 core unit tests passed, allocator tracking clean
odin run make.odin -file -- windows --no-config
    -> Windows product cross-build passed; no Windows shaping/runtime claim
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("tests/integration/unicode/x11_harness.py").read_text())'
    -> harness syntax check passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Fallback uses whole-grapheme coverage and fontconfig's charset match; it is
  not a Unicode sequence-scoring or user-configurable fallback policy.
- Fourteen fallback faces and sixty-four missed codepoints are deliberate
  resource bounds. Text needing more faces retains missing-glyph diagnostics.
- Non-Linux font discovery, shaping, rasterization, and product rendering remain
  unsupported or unvalidated as recorded by the existing platform adapters.
- The next task is M06-Detour-2: cut with Ctrl+X and Ctrl+Shift+C/V aliases.
