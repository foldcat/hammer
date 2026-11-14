## M01.04 done (2026-11-12 session)

Native input normalization (`docs/m01-04-input.md`):

- New backend-free `src/core/input`: editor-owned `Key` naming (119
  members), `Modifiers`/`Mouse_Button(s)` bit sets, the `Event` tagged
  union (key down/up, text, pointer down/up/move, scroll — logical
  coordinates), `normalize_text` (UTF-32 validation, never asserts on
  backend data), `describe` diagnostics with a pinned format.
- `src/main.odin` adapter: sapp keycode table, modifier/button mask
  translation, `normalize_sapp_event` (framebuffer→logical via
  `core/coords`), `state.scale` cache (validated once in
  `window_metrics`); ESC quit now dispatches through a normalized
  `Key_Down`. `tests/unit/input` added (6 tests).
- Validated: 45/45 unit tests leak-free; headless XTEST-fed input
  smokes at scale 1.0 and 2.0 (keys, modifiers, text, buttons, wheel,
  motion → logical coords, ESC-quit exit 0); debug/release/run smokes;
  panic path (132); Windows cross-build + Wine 11 smoke (exit 0). Real
  desktop, IME/dead keys, and real Windows input remain the recorded
  follow-ups.

