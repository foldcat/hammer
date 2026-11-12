# M00.04 — Spike Unicode clipboard round-trip and large transfer

**Status:** done (Linux/X11, validated headless via Xvfb). Wayland and
Windows are deferred by decision (2026-11-12) — see M00.03's decision
record; nothing about them is claimed here.

## What was built

A standalone spike program in `spike/clipboard/main.odin` that talks X11
directly through the pinned Odin `vendor:x11/xlib` bindings (native Xlib,
no shell clipboard utilities). It is a spike, not the M06.04 product
implementation: no delayed paste, no ownership manager, single-threaded,
one active INCR transfer at a time.

Modes (separate processes sharing one X display):

- `clipboard_spike serve <CLIPBOARD|PRIMARY> <file>` — owns the selection
  and serves the file's bytes as `UTF8_STRING` (plus the GTK
  `text/plain;charset=utf-8` atom), using the INCR protocol for payloads
  larger than 64 KiB. Prints `ready <sel> len=<n>` once ownership is
  acquired; runs until killed.
- `clipboard_spike get <CLIPBOARD|PRIMARY> [-o outfile] [--timeout-ms n]`
  — requests the selection as `UTF8_STRING`, follows INCR when announced,
  validates the payload as UTF-8, and writes it to stdout (or `outfile`).
  Diagnostics go to stderr.
- `clipboard_spike get <CLIPBOARD|PRIMARY> --targets` — lists the owner's
  advertised conversion targets.

Exit codes: 0 success, 1 runtime/X11 failure, 2 usage error. An X error
handler is installed so Xlib errors (e.g. a requestor dying mid-INCR)
become explicit errors instead of killing the process.

`spike/clipboard/demo.sh` is the harness: it runs the two modes against
one X display and asserts byte-identical round-trips, the INCR path, the
TARGETS list, and the post-exit persistence behavior. `make.odin` gained a
`clipboard-spike` build target that skips Sokol setup (the spike needs no
Sokol; it links `system:X11` only).

## Protocol coverage (what this spike implements)

| Feature                                               | Served/handled?                                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `TARGETS`                                             | Served: `TARGETS`, `UTF8_STRING`, `text/plain;charset=utf-8`                                  |
| `UTF8_STRING`                                         | Served and requested; payload validated as UTF-8 on receipt                                   |
| GTK `text/plain;charset=utf-8`                        | Served and accepted as a reply type                                                           |
| INCR                                                  | Served for payloads > 64 KiB in 64 KiB chunks; followed by the requestor with a 10 s deadline |
| CLIPBOARD and PRIMARY                                 | Both exercised                                                                                |
| `TIMESTAMP`, `MULTIPLE`, `XA_STRING`, `COMPOUND_TEXT` | Not implemented; requests are refused explicitly (property `None`)                            |

Deliberate exclusions, recorded for the M00.09 inventory:

- **No `XA_STRING`.** Serving Latin-1 would be lossy for non-ASCII text;
  the spike refuses instead of silently degrading. The real editor must
  decide this policy deliberately in M06.04.
- **No `TIMESTAMP`/`MULTIPLE`.** Refused cleanly; not needed to prove the
  round-trip properties this spike targets.
- **`CurrentTime` is used** for `SetSelectionOwner`/`ConvertSelection`.
  Works in practice; a production implementation should use real
  timestamps.
- **Same byte order assumed.** `XChangeProperty` format-32 data must be in
  server byte order. The spike checks `XImageByteOrder` against
  `ODIN_ENDIAN` at startup and refuses to run on mismatched servers.
  Always true on this machine (client and server both little-endian).

## Validation run (this machine, headless Xvfb)

Builds:

```
odin build spike/clipboard -vet -out:build/clipboard_spike   # ok
odin check spike/clipboard -vet -strict-style                # ok
odin check make.odin -file -vet -strict-style                # ok
odin run make.odin -file -- clipboard-spike                  # ok
odin run make.odin -file                                    # main app still builds; ok
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer    # window smoke test still clean (no regression from the make.odin refactor)
```

Demo (all assertions in `demo.sh`):

```
$ xvfb-run -a spike/clipboard/demo.sh build/clipboard_spike
OK: CLIPBOARD round-trip of 400 bytes
OK: PRIMARY round-trip of 400 bytes
OK: CLIPBOARD round-trip of 3276800 bytes
OK: PRIMARY round-trip of 3276800 bytes
OK: TARGETS listing (UTF8_STRING, text/plain;charset=utf-8)
OK: after owner exit, selection is gone (no clipboard manager on this X server)
ALL OK
```

The 400-byte fixture (`spike/clipboard/fixtures/unicode.txt`) contains
ASCII, Latin-1 accents, Greek, Cyrillic, CJK, combining marks, 4-byte
emoji, and RTL text; all four round-trips are byte-identical (`cmp`).

The 3.2 MiB payload takes the INCR path, verified by trace output:

```
note: serving 3276800 bytes via INCR (50 chunk(s) of 65536)
note: INCR transfer complete
received 3276800 bytes from CLIPBOARD via INCR (UTF-8 valid)
```

Additional checks run manually:

- No owner: `get` exits 1 with `error: conversion refused or no owner for
<sel>`.
- Unknown selection name: exit 2 with a usage error.
- `-o outfile` writes and matches the source.
- Timeout: with the owner frozen (`kill -STOP`), `get --timeout-ms 1500`
  exits 1 after ~1.5 s with `error: timed out waiting for SelectionNotify`.
- No tracking-allocator leaks reported by any mode.

## Findings

1. **Persistence (demonstrated, not assumed).** On X11 the clipboard is a
   selection owned by a live process. With no clipboard manager running
   (true of bare Xvfb and of this X session), the data is gone the moment
   the owner exits; the demo asserts that `get` fails after the owner is
   killed. A clipboard manager (xclipboard, Klipper, etc.) can take over
   ownership and serve the data after the owner exits — untested here, and
   M06.04 must handle both `SelectionClear` and manager-driven retrievals.
2. **libX11 1.8.14 (this Gentoo build) dereferences every
   `XGetWindowProperty` out-param unconditionally at function entry.** The
   first spike version passed `NULL` for `bytes_after_return` and crashed
   with a NULL write inside libX11 (confirmed by ASan + disassembly),
   despite the man page saying the return pointers "may be NULL". The
   spike now passes non-NULL pointers for all five out-params. M06.04 must
   keep this in mind for any other Xlib calls with optional out-params.
3. **sokol_app has no clipboard API.** The M06.04 product implementation
   will need direct Xlib selection code alongside the Sokol window, on the
   main thread (sapp callbacks run there, so a single-threaded Xlib
   integration is safe). This spike is that integration's prototype.
4. **Xlib is synchronous round-trip heavy.** The spike's requestor uses a
   2 ms poll loop with an overall deadline; a production editor should
   block on the X connection fd (`XConnectionNumber`) inside its own wait
   loop instead of polling, or move to xcb.
5. **Concurrent INCR transfers** are refused explicitly (single-slot
   state). A production owner must support several in-flight transfers;
   the editor's clipboard usage (one paste at a time) keeps this rare, but
   serving requests from other clients while an editor paste is in flight
   needs a per-(requestor, property) queue.
6. **UTF-8 validation** of received data is done by the spike and is cheap
   insurance against misbehaving owners; keep it in M06.04.

## Platform status (honest)

| Platform      | Status                                                                                                                                                               |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux/X11     | Validated headless (Xvfb): UTF-8 round-trip, INCR, both selections, TARGETS, error paths. Not yet run on a real desktop session or against a real clipboard manager. |
| Linux/Wayland | Deferred by decision (2026-11-12). `OpenDisplay` is X11-only; nothing claimed.                                                                                       |
| Windows       | Deferred by decision (2026-11-12). Nothing claimed.                                                                                                                  |

## Open follow-ups (feed M00.09 / M06.04)

- Run the spike once on a real X11 desktop and against a running clipboard
  manager (e.g. confirm data survives owner exit with one present).
- Decide the XA_STRING/COMPOUND_TEXT serving policy.
- Prototype fd-based event waiting instead of polling.
- Record the `XGetWindowProperty` out-param finding and the byte-order
  check in the M00.09 compatibility inventory.
