# M01.04 — Native input normalization

**Status:** done (Linux/X11 validated headless with real XTEST-fed
input events at scale 1.0 and 2.0; Windows cross-build validated under
Wine 11 with no input events — see the honest-status table).

This task delivers the input normalization layer (SPECS.md §18 M01.04):
backend raw events (sokol_app CHAR/KEY/MOUSE families) are translated
into editor-owned, backend-free input events with logical coordinates
— the bridge M06 (shortcuts/actions), M07 (Acme chords), and M05
(hit-testing) will consume.

## What was built

| Piece | Responsibility |
| ----- | -------------- |
| `src/core/input/input.odin` | Backend-free normalized event types: `Key` (editor-owned naming, 119 members), `Modifiers`/`Mouse_Button`/`Mouse_Buttons` bit sets, the `Event` tagged union (`Key_Down`, `Key_Up`, `Text`, `Pointer_Down`, `Pointer_Up`, `Pointer_Move`, `Scroll` — each carrying modifiers; pointer events in logical coordinates). `normalize_text` (UTF-32 validation: rejects NUL, surrogate halves, > U+10FFFF as `.Invalid_Input`, never asserts). `key_name`/`button_name`/`describe` diagnostics with a pinned, greppable format. |
| `src/main.odin` (adapter) | `sokol_key_map` (sapp keycode → editor `Key`, ~110 data lines; `WORLD_1/2` deliberately unmapped), `sokol_modifiers`/`sokol_buttons` (mask translation), `sokol_button_to_input`, `normalize_sapp_event` (full event translation incl. framebuffer→logical conversion via `core/coords`), `log_input_event` (debug diagnostics; pointer moves skipped — they are the high-frequency event). ESC quit now dispatches through a normalized `Key_Down` event. |
| `state.scale` | The editor-owned, always-valid scale cache: `window_metrics` validates the backend `dpi_scale` and falls back to 1.0 exactly once, at the boundary; input normalization trusts the cached value (SPECS.md §9.6 "never apply DPI twice"; the seed of the M05.06 DPI-change tracking). |
| `tests/unit/input/input_test.odin` | 6 tests: text validation (valid BMP/astral/boundary, all reject paths), key-name table completeness, describe format pinning, union round-trip, modifier bit-set semantics. |
| `make.odin` | `tests/unit/input` added to the core test list. |

## Design contracts

### Backend-freedom (M01 acceptance)

The core package imports `core:` packages plus sibling `coords`/`errs`
only; it builds without the Sokol collection and is covered by the
`test` target's no-Sokol rule. Every backend-specific fact — keycode
numbers, modifier-mask bits, button codes, framebuffer-pixel
coordinates — lives in the application layer (`src/main.odin`), which
is the adapter boundary.

### Events are facts, not actions (SPECS.md §10.1)

`Event` carries raw facts (key, text, button, logical position,
modifiers); semantic action dispatch (§10.1), shortcut mapping
(§10.3/§10.4), and chord recognition (§10.2) belong to M06/M07. The
one current consumer — ESC quits — reads a normalized `Key_Down` to
prove the chain end to end.

### Validation, not assertions

Backend input is external data (AGENTS.md §11.2): invalid character
codes are value errors (`.Invalid_Input`, event dropped with a warn),
unrecognized buttons are dropped at the adapter, and an invalid scale
never reaches normalization (validated once in `window_metrics`).
Nothing here asserts on backend data.

### Coordinates

Pointer events carry `coords.Logical_Point`; the adapter converts
framebuffer pixels at scale 1.0/2.0 (verified). Scroll `dx`/`dy` are
wheel notches, explicitly not pixels and not DPI-scaled (documented on
the type).

## Validation run (all commands executed this session)

```text
odin test tests/unit/input -vet -collection:hammer=src   -> 6/6, leak-checked
odin run make.odin -file -- test                         -> 45/45 (errs 6,
    logging 5, lifecycle 5, platform 1, config 14, coords 8, input 6)
odin run make.odin -file                                -> debug build
Headless input smoke, scale 1.0 (task-owned XTEST feeder finds the
    "Hammer" window via _NET_WM_NAME, focuses it, feeds keys/mouse):
    key down A / text 'a' (U+0061) / key up A
    key down LEFT_SHIFT mods=SHIFT / key down A mods=SHIFT /
        text 'A' (U+0041) mods=SHIFT / releases
    key down 1 / text '1' (U+0031)
    key down SPACE / text ' ' (U+0020)
    pointer down LEFT at 300,200 / pointer up LEFT at 300,200
    scroll dx=0 dy=1 at 300,200                       (wheel = X11 button 4)
    key down ESCAPE -> quit (reason=User_Request, source=esc), exit 0
Headless input smoke, scale 2.0 (Xft.dpi=192):
    window: 1600x1200 px, 800x600 logical
    pointer down/up LEFT at 150,100 (fed at physical 300,200)
    scroll dx=0 dy=1 at 150,100
    key down ESCAPE -> quit, exit 0
release build + smoke                                    -> exit 0
run mode (xvfb-run odin run make.odin -file -- run)      -> exit 0
panic path (HAMMER_TEST_PANIC)                           -> exit 132
Windows: ./build/make windows; Wine 11 smoke             -> exit 0
```

The XTEST feeder is a throwaway tool under `/tmp/opencode` (not
committed), built against the pinned `vendor:x11/xlib` plus the same
hand-written libXtst/libXext foreign blocks the M00.05 spike uses.
No product test hooks were needed: the feeder discovers the window
itself.

## Traps found (recorded for later tasks)

1. **Pinned Odin requires `#partial switch` for catch-alls**: a `case:`
   default does not satisfy enum/union exhaustiveness — the compiler
   still reports the remaining cases (verified with a minimal
   reproducer). Enum and union switches with a fallthrough default
   must be `#partial switch`.
2. **Odin anonymous procs are not closures**: a `proc(...)` literal
   cannot capture local variables (`Undeclared name` at capture
   points); thread values through parameters instead.
3. **X11 wheel events are button 4/5** in the sapp backend: `Button4`
   → `MOUSE_SCROLL` with `scroll_y = +1` (verified end to end:
   `scroll dx=0 dy=1`).
4. Carried from M01.03: Xlib async errors and the `_NET_WM_NAME`
   window discovery (used unchanged by the feeder).

## Honest status

| Platform  | Status |
| --------- | ------ |
| Linux/X11 | **tested headless**: unit tests, key/text/modifier/button/scroll/motion normalization via real XTEST events at scale 1.0 and 2.0, ESC-quit through the normalized path, release/run/panic smokes, leak-free exit. Real-desktop input and IME/dead-key paths remain recorded M00.05/M06.07 follow-ups (sapp has no XFilterEvent hook). |
| Windows   | **cross-build + Wine-validated** (adapter compiles under `-no-crt`; no input events fed — real Windows input untested, D-02). The same `sokol_key_map` serves the Windows backend since sapp normalizes Win32 virtual keys to its own keycode enum. |

## Follow-ups (owners)

- M01.05 queues these events with bounded capacity; the `Event` union
  is the queue element.
- M01.06 rendering consumes nothing from this task.
- M05.05 hit-testing consumes `coords.Logical_Point` positions;
  M05.06 turns `state.scale` into full DPI-change invalidation.
- M06.03 separates text input vs key commands on these types; M06.07
  routes IME commits into `input.Text` (the preedit/commit decision
  from M00.05 §5 remains open).
- M07 builds the §10.2 chord state machine on `Pointer_*` events.
- `FOCUSED`/`UNFOCUSED` and touch events are deliberately not
  normalized yet (no consumer); add them with their consumers.
