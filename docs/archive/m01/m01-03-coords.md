## M01.03 done (2026-11-12 session)

Logical/physical coordinate conversion (`docs/notes/m01-03-coords.md`):

- New backend-free `src/core/coords`: distinct `Physical_*`/`Logical_*`
  size/point structs, validated conversions both directions (divide /
  multiply by `dpi_scale`, finite 0 < scale ≤ 32, `.Invalid_Input` on
  garbage — no assertion on external input), points ↔ logical px
  (×96/72, SPECS.md §9.6), and `points_to_physical_px` as the full
  §9.6 chain.
- `src/main.odin` consumes it: `window_metrics` (startup info + RESIZED
  debug, scale-invalid → warn + fallback to 1.0), startup font log
  (12pt = 16 logical px = 32 physical px at 2×). Window service docs
  updated; `tests/unit/coords` added (8 tests).
- Validated: 39/39 unit tests leak-free; debug/release/run smokes;
  scale 1.0 and 2.0 (Xft.dpi 192); real X11 resize events at both
  scales fed by a task-owned throwaway resizer (not committed);
  custom-config font chain; panic path (132); Windows cross-build +
  Wine 11 smoke (exit 0). Real desktop and mixed-DPI dual-monitor
  remain the recorded follow-ups (M05.06/M01).

