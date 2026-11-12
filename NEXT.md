# What to do?

Complete the M00 section, one task per session, in order. Write your
documentations in `/docs`.

## Current task: M00.04 — Spike Unicode clipboard round-trip and large transfer

Scope (per decision 2026-11-12): **Linux/X11 only**. No Wayland, no Windows.

Allowed changes:
- A spike program demonstrating native X11 clipboard get/set with:
  - UTF-8 (and non-ASCII text) round-trip through the real clipboard.
  - Large transfers (e.g. 1 MiB) with the incremental/INCR path.
  - Both `CLIPBOARD` and `PRIMARY` selection targets where practical.
  - Explicit errors on failure.
- Notes on clipboard-manager persistence after exit (X11 ownership).
- Documentation in `/docs` (e.g. `docs/m00-04-clipboard.md`), recording what
  is validated versus assumed.
- Only touch `make.odin` if the spike needs a separate build target.

Acceptance:
- Round-trip of Unicode text and a large transfer are actually demonstrated
  on this machine (headless X session via Xvfb).
- No unverified claim about Wayland or Windows clipboard behavior.
- Findings feed the M00.09 compatibility inventory later.

## Next tasks after M00.04

- M00.05 Spike mixed-DPI and text-input/IME integration (X11 scope).
- M00.06 Wayland: close as a documented deferral (decision 2026-11-12).
- M00.07 Spike PTY (Linux) and asynchronous process output; ConPTY deferred.
- M00.08 Minimal FUSE deployment proof (needs an approved isolated mount).
- M00.09 Record architecture decisions and compatibility inventory.
