# M10.07d (slice) — Incremental terminal sync (performance)

**Status:** done on Linux/X11. The terminal previously re-serialized the entire
transcript — scrollback plus visible screen — and replaced the whole document
every frame the grid changed. With a large scrollback that is ~17 ms/frame of
pure sync work at 60 fps, which shows up as typing latency and as a visible
freeze when a full-screen app (Neovim) exits and the main screen's scrollback is
restored.

## Problem

`editor_terminal_sync` ran `grid_append_styled` (O(scrollback)) followed by a
whole-document `txn.Replace`, on every dirty frame. Two compounding costs:

1. Re-serializing every scrollback line (UTF-8 encode + style-run coalescing)
   each frame, even when only one visible cell changed.
2. Rebuilding the rope from scratch via a full-document replace.

Measured at 12,000 scrollback lines × 80 columns (~812 KB transcript):
full serialize ≈ 12.9 ms, full replace ≈ 3.9 ms. The visible screen alone is
~1.9 KB and serializes in ~90 µs and replaces in ~80 µs, so the incremental
path is ~100× cheaper per frame.

## What was built

### Console grid (`src/core/console/grid.odin`)

- `Grid.scrollback_total`: a monotonic count of lines appended to the active
  scrollback, reset to 0 whenever the scrollback is replaced (alternate-screen
  switch, erase-display mode 3). It lets a caller distinguish a pure append
  (counter and length both grow by k) from a front trim (length stays capped at
  `max_scrollback` while the counter grows) without tracking line identity.
- `grid_scrollback_total` accessor.
- Split `grid_append_styled` into `grid_append_scrollback_styled` (scrollback
  lines from an index) and `grid_append_visible_styled` (visible rows), so a
  caller can re-serialize only the part that changed.
- `grid_append_visible_styled` now serializes rows straight from the cells via
  `grid_append_row_styled` (no per-row `Line` allocation), which also removes a
  per-frame allocation leak under the virtual arena (`line_destroy` is a no-op
  there).

### Terminal sync (`src/terminal_ui.odin`)

`editor_terminal_sync` now picks one of three paths by comparing the grid's
scrollback length and counter against the last sync:

- **Visible-only** (the common case — a keystroke, cursor move, partial redraw):
  rebuild only the visible tail and `txn.Replace` just that range.
- **Append** (new lines scrolled off, no trim): `txn.Insert` the new scrollback
  bytes at the scrollback/visible boundary and replace the visible tail in the
  same transaction.
- **Full resync** (front trim, alternate-screen switch, or clear): the previous
  whole-transcript rebuild.

`Editor_Terminal` tracks `scroll_bytes` (the document offset where the visible
screen begins), `scroll_run_count` (how many leading `styles` entries describe
the scrollback), and the last-synced scrollback length/counter. Style runs are
maintained incrementally: scrollback runs are kept, new ones are offset by
`scroll_bytes`, and visible runs are rebuilt each frame and offset after the
scrollback.

### Leak fix (`src/terminal_ui.odin`)

The grid, its scratch buffers, and the terminal's `render`/`styles` buffers were
allocated from the permanent virtual arena, which cannot free individual
allocations — so every scrolled-off scrollback line (its `[]rune` text and
`[]Run` runs) leaked for the life of the process, growing without bound under
sustained output. `editor_alloc_terminal_buffer` now passes
`runtime.heap_allocator()` to `grid_stream_init` and allocates `render`/`styles`
from it, so `line_destroy`, `grid_destroy`, and `delete` actually reclaim the
memory. Truly program-lifetime data (`job_name`, the document) stays on the
permanent arena.

## Tests

- `tests/unit/console/grid_test.odin`:
  - `test_grid_append_styled_split` — the split scrollback/visible serialization
    matches `grid_append_styled` byte-for-byte and run-for-run.
  - `test_grid_scrollback_total` — the counter counts appends and resets on
    alternate-screen switch and erase-display mode 3.
  - `test_grid_scrollback_trim_frees` — feeds past a small `max_scrollback` so
    the front trim runs; the test runner's tracking allocator flags any leak,
    pinning the trim-free path.
- `tests/unit/txn/txn_test.odin`: `test_insert_at_replace_start` pins the
  terminal's two-op transaction (insert exactly at a replace's start), asserting
  the inserted bytes land between the kept prefix and the replacement.
- `tests/integration/terminal/x11_harness.py`: added a `seq 1 300` step so the
  X11 smoke test exercises the append path end to end.

## Validation

```text
odin test tests/unit/console -vet -collection:hammer=src -> 102/102 passed
odin test tests/unit/txn    -vet -collection:hammer=src -> 29/29 passed
odin run make.odin -file -- test                         -> full core suite passed
odin run make.odin -file -- terminal-test                -> 6/6 X11 terminal checks passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> clean
odin check src -vet -collection:sokol=third_party/sokol/sokol -target:windows_amd64 -define:SOKOL_USE_GL=true -> clean
git diff --check                                          -> clean
```

## Not validated and next task

- The scrollback front-trim path is exercised only indirectly (the default
  `max_scrollback` is 10,000 lines, beyond what the smoke test generates); it
  falls back to a full resync, which is correct but not unit-pinned.
- A wrong `scrollback_total` (e.g. after a resize while the alternate screen is
  active) can only force a full resync, never stale content, so the counter is
  not preserved across the alternate-screen swap.
- The document's chunk store still retains orphaned chunks from every sync (the
  rope is persistent and content-addressed with no GC). The incremental sync
  shrinks this dramatically (visible-tail deltas instead of whole-transcript
  rebuilds), but a long-lived terminal still accumulates the per-frame visible
  screens until the buffer closes. Reclaiming those orphans needs a chunk-store
  GC or a periodic document rebuild — out of scope here.
- The actual interactive Neovim/htop runs remain manual (M10.07d).
