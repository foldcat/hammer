# M05.06 — DPI change invalidation

**Status:** done; Linux/X11 scale transitions and synthetic mixed-DPI monitor
selection are validated. Real dual-monitor movement and non-Linux runtime DPI
were not tested.

## Scale and layout state

`src/core/dpi` owns the backend-free transition logic. `dpi.State` records the
font points, validated scale, exact physical font size, rounded glyph-cache pixel
size, and a generation. `update` returns independent layout and glyph change
flags. Repeated identical values do not advance the generation. Invalid points or
scales return an error without changing the last valid state.

The 12 pt scale table produces 16, 20, 24, and 32 physical pixels at 100%, 125%,
150%, and 200%. Logical layout remains 16 px at each scale. A 100% to 101%
transition invalidates layout while retaining the same 16 px glyph size. Existing
shaped-run hit testing continues to divide physical advances by the current scale,
so DPI is not applied twice.

`window_metrics` is the single product boundary for scale updates. Startup,
RESIZED, and once-per-frame polling all use it. It updates the generation and
invalidates the glyph cache only when the rounded physical glyph size changes.
An invalid backend scale retains the previous valid scale (initially 1.0), and an
unchanged poll emits no log or cache work.

## X11 mixed-DPI tracking

The pinned sokol_app X11 backend reads display-wide Xft.dpi only at startup. The
product adapter in `src/window_dpi_linux.odin` therefore polls RandR every 15
frames, using the native sokol Display and Window handles. It translates the
window bounds into root coordinates and selects the monitor with the largest
overlap, with nearest-monitor fallback when there is no overlap.

The first valid monitor DPI is the reference. Subsequent scale is
`sapp_base_scale * current_monitor_dpi / reference_dpi`, preserving the startup
Xft policy while tracking relative per-monitor physical density. Invalid or
missing monitor data retains the last valid scale. Queries are synchronous on the
UI thread, bounded to 64 monitors, and free the native RandR result on every path.
Non-Linux builds continue to use sokol's dynamic `dpi_scale` directly.

## Glyph atlas lifetime

`glyphcache.reset` clears entries and pixels but retains page/key allocations,
resets shelf packing, and marks existing pages dirty. DPI changes therefore do
not accumulate a new permanent-arena allocation for every scale. The GPU sync
recreates and reuploads dirty images, then prewarms `A` for all three font roles
at the new physical size. Existing page/entry budgets and normal destruction are
unchanged.

The product has no retained shaped-line cache yet. The DPI generation is the
invalidation boundary for that later owner; this task does not claim product text
drawing or a shaped-line cache implementation.

## Tests and validation

Five DPI unit tests cover the scale table, no-op updates, fractional same-glyph
transitions, invalid-update atomicity, largest-overlap and nearest-monitor
selection, mixed-DPI round trips, and invalid physical data. A sixth glyphcache
unit test proves reset retains page/key backing storage, clears pixels and
entries, and forces a fresh upload/rasterization.

```text
odin test tests/unit/dpi -vet -collection:hammer=src
    -> 5/5 passed
odin test tests/unit/glyphcache -vet -collection:hammer=src
    -> 6/6 passed
odin run make.odin -file -- test
    -> all 256 unit tests passed
odin run make.odin -file -- text-test
    -> 20/20 native text tests passed
odin run make.odin -file
    -> Linux debug build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=20 HAMMER_LOG= ./build/hammer
    -> ordinary X11/RandR path, clean 20-frame shutdown
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=12 \
    HAMMER_TEST_DPI_SCALES=1,1.25,1.5,2,1.5,1.25,1 \
    HAMMER_RENDER_PROBE=4 HAMMER_LOG= ./build/hammer
    -> six transitions, one page and three entries after each rebuild, misses
       3 -> 21, exact theme colors at scale 1.5, clean shutdown
odin run make.odin -file -- windows
    -> windows_amd64 cross-build passed
git diff --check
    -> no whitespace errors
```

`HAMMER_TEST_DPI_SCALES` is a bounded test-only sequence (at most eight valid
scales); the final value is held. It lets the real frame/cache path exercise all
required scale values under Xvfb, which cannot express a mixed-DPI monitor pair.

## Limits and next task

- Real mixed-DPI monitor movement, fractional physical-monitor densities, and
  resize/touchpad behavior on a desktop were not exercised.
- Windows was cross-built but not runtime-tested; macOS and Wayland DPI runtime
  behavior remain unvalidated.
- No real shaped-line invalidation or visual text output is claimed. M05.08 owns
  mixed-script/DPI visual fixtures.
- M05.07 should bound visible-range shaping and measurement for huge lines,
  including safe shaping boundaries and explicit fallback behavior.
