## M01 done (2026-11-12 session, M01.06)

Render basic column/tag/body rectangles (`docs/m01-06-render.md`) —
this closes M01:

- New backend-free `src/core/layout`: `Rect`/`Window` (frame/tag/body)
  geometry with degenerate-size collapse and `.Invalid_Input`
  validation; `src/render.odin` (application layer) draws them with
  sokol_gfx (embedded GLSL 410 colored-quad shader, write-transient
  vertex buffer), recomputing the layout every frame from the window
  metrics, cached scale, and configured theme/font size.
- New render probe test hook (Linux/X11, raw-GL readback): proves
  headlessly, byte-exactly, that config edits change rendered colors
  and font sizes change the tag strip height — the M01 acceptance —
  at scale 1.0/2.0, after live resizes, debug and release.
- Validated: 57/57 unit tests leak-free (layout 6 new); pixel probes
  (default config `tag=#262626 body=#161616`; custom config
  `tag=#446688 body=#112233`; 21pt font flips the below-tag sample);
  Windows cross-build + Wine 11 smoke with the renderer running
  (exit 0). Real-desktop visual check remains the standing follow-up.

M01 overall status: all six tasks done and validated headless;
real-desktop and real-Windows validation stay recorded as the M01/D-02
follow-ups.

