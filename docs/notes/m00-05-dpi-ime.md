# M00.05 — Spike mixed-DPI and text-input/IME integration

**Status:** done (Linux/X11, validated headless via Xvfb). Wayland and
Windows are deferred by decision (2026-11-12); nothing is claimed for
them.

## What was built

`spike/dpi_ime/` contains two spike programs plus a demo harness:

- `main.odin` — native X11 probe binary (`build/dpi_ime`) with modes:
  - `probe` — prints the DPI inputs that exist on X11: the Xft.dpi
    resource, the mm-based screen DPI, per-monitor RandR data
    (`XRRGetMonitors` with physical mm per monitor), and XTEST
    availability.
  - `set-dpi <v>` / `clear-dpi` — writes/removes the `Xft.dpi` entry in
    the root `RESOURCE_MANAGER` property (the xrdb mechanism) and then
    **holds the connection open** until killed. The hold matters: X
    servers reset their state when the last client disconnects, so a
    short-lived writer would lose its own write.
  - `xim` — the XIM bridge prototype (see below).
  - `keys --window <id> [--motion x,y]` — feeds fake key/mouse events
    via XTEST to another window (drives the sapp probe app).
- `app/main.odin` — a minimal sapp window (`build/dpi_ime_app`, no
  rendering) that reports the physical window size, `sapp.width()/height()`,
  `sapp.dpi_scale()`, `sapp.high_dpi()`, the Xft.dpi resource, the mm-based
  DPI, and logs CHAR/KEY/MOUSE/RESIZED events.
- `xutil/` — small shared helper package (resource read, DPI computation).
- `demo.sh` — headless demo under Xvfb with assertions for everything
  below. `make.odin` gained a `dpi-ime-spike` target.

This is spike code, not the product implementation (M01.03/M05.06/M06.07
own the real work).

## Finding 1 — the pinned sokol_app X11 DPI model (verified)

Code paths in the pinned `third_party/sokol-c/sokol_app.h`
(`_sapp_x11_query_system_dpi`, `_sapp_x11_create_window`,
`_sapp_x11_update_dimensions`, line 14453) plus empirical runs:

- **Source of truth: the `Xft.dpi` resource.** sapp reads it from the
  root `RESOURCE_MANAGER` property **once at init** and falls back to
  96.0 with a warning. The mm-based screen DPI (the GLFW-style
  computation) is _deliberately commented out_ in sapp.
- **`sapp.dpi_scale()` = Xft.dpi / 96, always, on X11** — it is not gated
  by the `high_dpi` flag. `sapp_desc.high_dpi` is a **no-op on X11**
  (verified: with the flag set, scale stays 1.0, window unscaled).
- **The physical window is pre-scaled** at creation: `physical =
desc_size * scale`. `sapp.width()/height()` report the framebuffer
  size, which equals the physical size on X11 (scale 2.0 → 400x300 desc
  becomes a physical 800x600 window and `sapp.width()` returns 800).
- **Mouse coordinates arrive in framebuffer pixels**, consistent with
  `sapp.width()` (verified: mouse at physical 300,200 reported as 300,200
  at scale 2.0). No coordinate mismatch — but the app must divide
  `sapp.width()/height()` by `dpi_scale` to recover logical (desc) units.
- **Static and display-wide.** No re-query on changes, no per-monitor
  scale, no DPI-change events; RESIZED only fires on framebuffer size
  change. Mixed-DPI monitor handoffs are invisible to sapp.

Consequence for the editor: on X11, sapp has already applied the DPI
scale to the window, framebuffer, and (implicitly) coordinates — "never
apply DPI twice" (§9.6) means the editor must treat `sapp.width()` as
_scaled_ and divide by `sapp.dpi_scale()` for logical layout, then
recompute fonts/atlas at scale changes. Per-monitor DPI would need the
editor's own RandR tracking (`XRRGetMonitors` per-monitor `mwidth/mheight`
— demonstrated available via the probe; a window-move watcher is not in
sapp).

## Finding 2 — what sapp delivers for text input (verified)

Code path: `_sapp_x11_on_keypress` uses `XLookupString` for the keysym and
a static `_sapp_x11_keysym_to_unicode` table (Latin-1 direct, 0x01000000
UCS keysyms direct, table lookup for the rest). Consequences:

- Plain ASCII text arrives as CHAR events (verified: `a`, `A` via shift,
  `1`, space, fed by XTEST fake keys).
- **No XIC, no XFilterEvent on KeyPress** (sapp only filters
  ClientMessage events). Therefore: **no dead-key composition, no Compose
  sequences, no IME** through sapp on X11. AltGr works only insofar as the
  keysym already reflects the modifier state.
- `M06.07` needs a native bridge; sapp cannot provide preedit/commit.

## Finding 3 — the XIM bridge prototype (demonstrated)

`dpi_ime xim` proves the native mechanics headlessly (no external IM
server; Xlib's built-in XIM):

- `XOpenIM` succeeds with the en_US.UTF-8 locale under Xvfb.
- The built-in XIM advertises styles `0x810` (PreeditNone+StatusNone) and
  `0x408` (PreeditNothing+StatusNothing) — **no preedit-callbacks style
  headless**. Real IM servers (ibus XIM bridge etc.) advertise
  `XIMPreeditCallbacks`; the spike implements that path (style
  negotiation + callback registration) but reports `exercised=no` here.
  Honest status: **commit path validated headless; preedit callbacks
  implemented but only validatable on a desktop with an IM server.**
- Dead-key composition is demonstrated end to end: the spike temporarily
  remaps the grave key to `dead_acute` (`XChangeKeyboardMapping`), feeds
  XTEST key events, `XFilterEvent` consumes the dead key, and
  `XmbLookupString` commits `é` (`LookupBoth`), followed by a plain `a`.

Integration gotchas discovered (each is a documented trap for M06.07):

1. **XimLocal caches the keymap at IC creation** — the remap must happen
   before `XOpenIM`/`XCreateIC`.
2. **Drain MappingNotify before opening the IM**, calling
   `XRefreshKeyboardMapping`, so Xlib's client-side keymap cache is fresh
   when the XIM snapshots it.
3. **Never pass MappingNotify through XFilterEvent** — the local filter
   would parse the mapping event's bytes as a key event and corrupt its
   compose state.
4. **Style bit values** on this machine (from this Xlib.h):
   `XIMPreeditCallbacks=0x0002`, `XIMStatusNothing=0x0400`,
   `XIMPreeditNothing=0x0008`, `XIMPreeditNone=0x0010` — not the values
   some references show; read the header.
5. **The `XN*` macros are plain strings** without the `XN` prefix
   (`XNQueryInputStyle` == `"queryInputStyle"`, etc.).
6. **Odin block-scoped defers** (AGENTS.md §10.6): a restore-defer placed
   inside an `if` block fired at _block_ exit and restored the keymap
   before the XIM ever read it — the spike's most instructive bug.
7. `XTestFlush` lives in **libXext**, while the other `XTest*` calls live
   in libXtst.

## Finding 4 — headless test-environment notes

- **Xvfb resets all server state when the last client disconnects.**
  Any process that writes root-window state (X resources, selections,
  keymaps) must keep a connection open while consumers read it.
- **Xvfb cannot express per-screen DPI** (one global resolution, no
  per-screen physical size), so a mixed-DPI monitor handoff cannot be
  validated headless. The per-monitor data source (RandR) is demonstrated,
  but real mixed-DPI validation needs a desktop with two monitors — an
  honest, recorded limitation.

## Validation run (this machine, headless Xvfb)

Builds:

```
odin check spike/dpi_ime -vet -strict-style -collection:spike=spike    # ok
odin check spike/dpi_ime/app -vet -strict-style -collection:sokol=... # ok
odin run make.odin -file -- dpi-ime-spike                              # ok
odin run make.odin -file -- clipboard-spike                            # still ok (no regression)
odin run make.odin -file                                               # main app still ok
```

Demo:

```
$ xvfb-run -a spike/dpi_ime/demo.sh build/dpi_ime build/dpi_ime_app
XTEST: yes (version 2.2)
Xft.dpi: unset
screen 0: 1280x1024 px, 100 dpi (mm-based)
monitors: 1
  monitor[0]: "screen" 1280x1024+0+0 mm=339x271 (95.9 dpi)
OK: default DPI (physical 400x300, sapp 400x300, dpi_scale 1.0, ASCII chars via CHAR events)
OK: Xft.dpi=192 (physical/sapp 800x600, dpi_scale 2.0, mouse in framebuffer px)
OK: clear-dpi removes the resource (probe confirms unset)
OK: sapp_desc.high_dpi is a no-op on X11 (scale stays 1.0, window unscaled)
locale: en_US.UTF-8
supported styles: 2
  style[0]: 0x810 (PreeditNone+StatusNone)
  style[1]: 0x408 (PreeditNothing+StatusNothing)
XIMPreeditCallbacks supported: false
chosen style: 0x408 (PreeditNothing+StatusNothing)
key event consumed by the input method (XFilterEvent)
key event consumed by the input method (XFilterEvent)
lookup: status=LookupBoth keysym=0xe9 bytes=2
commit: "é"
lookup: status=LookupBoth keysym=0x61 bytes=1
commit: "a"
committed total: "éa"
preedit-callbacks: exercised=false
RESULT: OK
OK: XIM bridge prototype (dead-key composition commit path)
ALL OK
```

## Platform status (honest)

| Platform      | Status                                                                                                                                                                                                                                         |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux/X11     | Validated headless (Xvfb): sapp DPI model at Xft.dpi 96/192, high_dpi no-op, mouse-coordinate semantics, ASCII CHAR events, XIM dead-key commit path. Not run on a real desktop, not against a real IM server, no real mixed-DPI monitor pair. |
| Linux/Wayland | Deferred by decision (2026-11-12). Nothing claimed.                                                                                                                                                                                            |
| Windows       | Deferred by decision (2026-11-12). Nothing claimed.                                                                                                                                                                                            |

## Open follow-ups (feed M00.09 / M01.03 / M05.06 / M06.07)

- Real-desktop validation: mixed-DPI monitor handoff (sapp: static
  display-wide Xft.dpi — the editor will need its own RandR monitor
  tracking), IME with an ibus XIM bridge (preedit callbacks path).
- M06.07 integration question: sapp owns the X11 event loop and consumes
  KeyPress internally with no pre-event hook, so a real XIM bridge needs
  one of: an upstream sapp hook, a local sapp patch, or an editor-owned
  event loop. Decision needed before M06.07.
- Record the DPI model, XIM traps, and the Xvfb reset behavior in the
  M00.09 compatibility inventory.
