# M07.09 — Configurable wrapping and horizontal scrolling

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Configuration and view ownership

The compiled configuration accepts `wrap: "soft"` and `wrap: "truncate"`.
Truncate is the default and preserves the previous behavior. The generated
schema version is 4, and `configs/example.yaml` documents the setting. Invalid
values and non-string YAML input are rejected. The resolved description and
staged source include the selected mode.

Each `core/view.View` owns its `wrap_mode` and `horizontal_offset`. Startup and
Look initialize new views from the compiled default. Soft views always keep the
horizontal offset at zero. Truncate views accept horizontal wheel/touchpad input
at the pointer's body, without changing selection or activating another window.
Ctrl+wheel remains zoom. Offsets are finite and globally bounded; they are not
incorrectly clamped against each individual logical line.

## Shared visual layout

`src/text/shaping/wrap.odin` turns a shaped line into visual rows at grapheme
cluster boundaries. Each row records its global logical x interval, and
row-local hit-testing prevents identical x positions on separate rows from
mapping to the wrong source byte. Empty lines and invalid inputs are handled.

`text_render_native.odin` and `text_hit_native.odin` use the same row layout,
font scale, viewport width, and horizontal offset. Soft-wrapped logical lines
consume multiple visual rows and following lines move accordingly. Rendering
clips glyphs, selection spans, preedit underlines, and carets to the correct row.
Tags remain single-line truncate views. Truncate mode applies
`-horizontal_offset` to rendering and adds it during hit-testing, so clicks after
scrolling target the displaced source text.

Existing bounded visible-line shaping remains in place; this task does not shape
an entire huge line synchronously or add persistent wrap caches.

## Regression coverage

Config tests cover the default, both YAML modes, generated enum syntax, and
invalid input. View tests pin independent mode/offset state. Native text tests
cover exact row split positions, row-local hits, empty lines, and invalid widths.

`tests/integration/wrap/x11_harness.py`, exposed as `wrap-test`, builds separate
soft and truncate binaries and uses isolated files and real X11 input. It checks:

- Three visual rows for a soft-wrapped Unicode long line plus its successor.
- One row per logical line in truncate mode.
- No rendering change when soft mode receives horizontal input.
- Wrapped-row editing inserts at source byte 40 without damaging the next line.
- Horizontal right/left input changes and restores truncate rendering.
- A click after horizontal scrolling inserts at source byte 7 and saves exactly
  that result.

The X11 regression exposed an initial per-line clamp bug: a short following line
reset the shared offset after the long line rendered. Offset lifetime is now
view-wide rather than line-local. Temporary diagnostics and image captures were
removed after the corrected scenario passed.

## Validation

```text
odin run make.odin -file -- wrap-test
    -> all seven soft/truncate X11 checks passed
odin run make.odin -file -- test
    -> all 363 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 40 native text tests and four visual golden hashes passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord checks passed
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
    -> all seven compatibility stages passed
odin run make.odin -file -- unicode-test
    -> all Unicode/fallback checks passed
odin run make.odin -file -- ligature-test
    -> enabled/disabled native ligature checks passed
odin run make.odin -file -- emoji-test
    -> all color-emoji checks passed
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

No native Windows/Wine run or real-desktop review was performed. Vertical
viewport scrolling and scrollbar behavior remain M07.10. Horizontal offset is
bounded but not persisted across sessions; persistent per-project view state is
M16 work.

## Next task

M07.10 should add vertical viewport scrolling and Acme scrollbar rendering and
interaction, preserving independent view origins and the visual-row mapping
introduced by soft wrapping.
