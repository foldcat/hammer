# M05.09 — Native ligature coverage and configuration

**Status:** done on Linux/X11. Native HarfBuzz shaping, FreeType rasterization,
caret/selection geometry, compiled configuration, and real product rendering are
validated with ligatures both enabled and disabled. Non-Linux shaping and product
rendering remain unvalidated.

## Shaping behavior

`src/text/shaping/shape_linux.odin` now disables the optional OpenType `liga`,
`clig`, `dlig`, `hlig`, and `calt` features when `Options.ligatures` is false.
`calt` is required for common programming ligatures: the previous two-feature
policy still formed JetBrains Mono's `==` ligature with configuration disabled.
Required `rlig` and other script-shaping features remain enabled; existing Arabic
and mixed-script tests and visual goldens are unchanged.

The existing configuration path already carried `ligatures` from YAML through
`config.Resolved` into product shaping and hit testing. `configs/example.yaml`
now explicitly describes standard/contextual ligatures and the component-glyph
fallback. No new configuration key or atlas key is needed: different ligature
modes produce their glyph IDs through shaping before cache lookup.

## Deterministic native fixtures

Two small bundled fonts make the previously synthetic ligature coverage real:

- `FixtureLigature.ttf` (6,072 bytes) is an `fi` subset of Noto Sans Regular,
  generated with pinned `hb-subset` 12.3.2. The existing Noto `LICENSE.txt`
  applies. Native enabled shaping produces one `fi` glyph; disabled shaping
  produces the original `f` and `i` glyphs.
- `FixtureCodingLigature.ttf` (11,000 bytes) contains space and `=` from
  JetBrainsMono Nerd Font Mono Regular, retaining the contextual
  `equal_equal.liga` substitution. Enabled shaping uses an alternate blank plus
  the ligature glyph while preserving the two-character advance; disabled shaping
  produces two ordinary `=` glyphs. `LICENSE_CODING_LIGATURE.txt` carries the
  JetBrains Mono and Nerd Fonts notices and SIL OFL 1.1 terms.

Generation inputs are installed fonts only; tests load the bundled subsets and
never consult fontconfig or user font directories. The commands were:

```text
hb-subset /usr/share/fonts/noto/NotoSans-Regular.ttf \
    --text='fi' --output-file=FixtureLigature.ttf
hb-subset <installed-JetBrainsMonoNerdFontMono-Regular.ttf> \
    --text='= ' --output-file=FixtureCodingLigature.ttf
```

License references:
[JetBrains Mono OFL](https://raw.githubusercontent.com/JetBrains/JetBrainsMono/master/OFL.txt)
and [Nerd Fonts licensing](https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/LICENSE).

`tests/integration/textdeps/ligature_test.odin` verifies:

- one native `fi` glyph versus two component glyphs and nonzero glyph IDs;
- total/run/glyph advances and two grapheme clusters with the ligature advance
  subdivided at source byte 1;
- caret and hit-test round trips at both ligature boundaries and the midpoint;
- independent selection spans for each source grapheme;
- successful nonempty FreeType atlas rasterization and different rendered ink
  for enabled/disabled text in both fixtures;
- the `calt` regression: disabled `==` returns two ordinary equal glyphs.

The cache test deliberately treats HarfBuzz's 26.6 shaping advances as the layout
authority rather than requiring them to equal FreeType's hinted cache advance.

## Product configuration validation

`make.odin -- ligature-test` stages two isolated configurations that differ only
in `ligatures`, both using `FixtureLigature.ttf` through `font_path`. It builds
`build/hammer-ligatures-on` and `build/hammer-ligatures-off`, restores the staged
built-in defaults afterward, and runs `tests/integration/ligature/x11_harness.py`
under a fresh Xvfb display.

The harness types real `f`/`i` key events into each product, checks text pixels
change, undoes the typing run, verifies the initial pixels return, and exits
through the ordinary clean close path. The enabled and disabled rendered hashes
differ (`69f55b5f…` versus `19507c57…` in the validated run). Logs are checked for
the expected compiled flag and fixture path. Each run uses a unique sandbox,
bounded process timeouts, and owned-process cleanup; bytecode generation is
disabled so the shared Python X11 helper leaves no cache artifacts.

## Validation

Using pinned Odin `dev-2026-11` and the repository's pinned native text stack:

```text
odin run make.odin -file -- text-test
    -> all 30 native text tests passed, allocator tracking clean
    -> all four existing visual golden hashes matched
odin run make.odin -file -- ligature-test
    -> enabled/disabled product rendering, configuration logs, undo, and close passed
odin run make.odin -file -- test
    -> all 300 core unit tests passed, allocator tracking clean
odin run make.odin -file -- typing-test
    -> all existing real X11 typing, mouse, clipboard, undo, and close checks passed
odin run make.odin -file -- windows
    -> Windows product cross-build passed; no non-Linux shaping runtime is claimed
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("tests/integration/ligature/x11_harness.py").read_text())'
    -> harness syntax check passed
git diff --check
    -> no whitespace errors
```

## Limits and next task

- Only Linux/X11 shaping, rasterization, and product rendering were exercised.
  Windows product compilation does not validate Windows shaping or rendering.
- `fi` and `==` cover standard and contextual ligatures. Discretionary and
  historical features are disabled by the same policy but have no dedicated font
  fixture. Required-script behavior is covered by existing native/golden tests.
- The product comparison is structural and hash-based on the pinned Xvfb stack,
  not a promise of byte-identical GPU output across drivers.
- M05.10 should implement color emoji and complete emoji-sequence rendering with
  correct metrics and grapheme boundaries.
