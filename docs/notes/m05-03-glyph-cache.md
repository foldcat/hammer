# M05.03 — Glyph atlas/cache lifecycle

**Status:** done; CPU cache, native rasterization, and Linux GPU lifecycle are
validated. Text drawing and shaping remain later tasks.

## Cache and ownership

`src/text/glyphcache/glyphcache.odin` owns a bounded map of glyph entries and
single-channel CPU atlas pages. Defaults are four 1024×1024 R8 pages and 4096
entries (at most 4 MiB of CPU pixels); both page count and entry count are fixed
at initialization. Tests use smaller explicit budgets.

Cache keys contain font ID, face index, glyph ID, physical pixel size, render
mode, and up to four complete `(tag, value)` variation coordinates. There is no
hash-only variation shortcut. Invalid keys, oversized bitmaps, malformed input,
and rasterizer failures return errors without discarding existing entries.

Pages use shelf packing with one-pixel padding. A miss rasterizes first and
then copies pixels into a page, so borrowed FreeType bitmap memory is never
retained. Empty glyphs return metrics without consuming an atlas entry. Hits
update page recency; when space or entry budget is exhausted, the entire least-
recently-used page is evicted and its slot reused. `clear` and `destroy` release
all page allocations, and destruction is idempotent.

`src/text/glyphcache/rasterize_linux.odin` sets the FreeType pixel size, loads
and renders the glyph, and returns a borrowed gray bitmap plus 26.6 metrics.
Only normal coverage is currently accepted; mono and other native modes return
`.Unsupported` even though the key can represent them. Cache and face mutation
are UI-thread-only. Other platforms have explicit unsupported adapters.

## GPU lifecycle

`src/glyph_atlas.odin` mirrors live CPU pages into bounded Sokol R8 images.
The pinned Sokol API prohibits initial data on write-unsealed images and
requires sealing after upload. Therefore each dirty page is recreated, uploaded
with `sg.write_image_unsealed`, sealed with `sg.seal_image`, and checked for
`.VALID`. Clean pages are untouched; removed pages are destroyed. Cache clearing
also truncates the GPU page list. Product cleanup destroys GPU images before
`sg.shutdown` and CPU cache entries before their font faces.

`src/glyph_cache.odin` prewarms glyph `A` for each role at the current physical
font size and syncs after every role. This exercises initial creation and dirty-
page recreation without pretending to implement text rendering. Startup logs
page/entry/hit/miss/eviction counts; failure destroys partial resources and
leaves the existing rectangle renderer available.

## Validation

```text
odin test tests/unit/glyphcache -vet -collection:hammer=src
    -> 5/5 cache tests passed (complete keys, hits, copying/padding, dirty
       tracking, page LRU eviction, entry budget, errors, empty glyphs, clear,
       repeated destroy)
odin run make.odin -file -- text-test
    -> 9/9 native tests passed, including real FreeType glyph cache reads/hits
odin run make.odin -file -- test
    -> all 250 unit tests passed
odin run make.odin -file
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> one valid GPU atlas page, three role glyphs, repeated dirty syncs,
       clean shutdown, exit 0
odin run make.odin -file -- windows
    -> windows_amd64 cross-build passed
git diff --check
    -> no whitespace errors
```

During development Sokol validation rejected initial data on an unsealed image;
that path was replaced by the required create/write/seal sequence and rerun
successfully. No crash artifact was left in the repository.

## Limits and next task

- No glyph is drawn by the product yet; atlas correctness is tested through CPU
  pixels and native resource lifecycle, not a visual text fixture.
- Native mono/LCD/BGRA rasterization and variable-coordinate application are not
  implemented. GPU failure injection and non-Linux GPU runtime were not tested.
- M05.04 should implement Unicode run segmentation and HarfBuzz shaping into
  positioned runs, using these cache keys/entries and preserving cluster-to-
  source mappings for later hit testing.
