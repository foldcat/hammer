# M00.03 — Build/run a window (Linux/X11)

**Status:** done (Linux/X11). Windows deferred by decision — see below.

## Decision record

Decision taken with the repository owner on 2026-11-12:

- **Lock in on X11 for now.** Wayland work is deferred (`M00.06` will be
  closed as a recorded decision, not a spike).
- **No Windows support this early.** The Windows halves of `M00.03`,
  `M00.04`, `M00.05`, `M00.07`, `M00.08` are deferred; the compatibility
  inventory (`M00.09`) must record this honestly.

This supersedes the original "Windows and Linux" wording of M00.03 for
the current milestone pass. SPECS.md platform tiers (§1.2) still list
Windows and Wayland as Tier-1 targets for later milestones; this
decision only reorders the work.

## What was built

- `src/main.odin`: a minimal Sokol application shell:
  - `sokol_app` + `sokol_gfx` + `sokol_glue` window (800x600, "Hammer").
  - Clears the framebuffer to a dark color each frame.
  - ESC key or window close quits; clean `sg.shutdown()`.
  - Prints the active graphics backend and window metrics at startup.
  - Keeps the tracking-allocator leak report on shutdown (covers Odin-side
    allocations in `main` scope; Sokol callbacks use
    `runtime.default_context()` per the upstream examples and are not
    covered by the tracker).
- Test hook: `HAMMER_AUTOQUIT_FRAMES=<n>` requests quit after `n` frames.
  Unset in normal use; exists so the headless smoke test can prove
  startup, frame rendering, and shutdown deterministically.

## Build system (make.odin)

`make.odin` now self-configures the Sokol dependency on Linux:

1. **Pinned C sources.** If `third_party/sokol-c/` is missing, it downloads
   `floooh/sokol` tarball at commit `93aa187b5d387cc24b7290b3ca3f13f61e139e7c`
   (the revision the pinned sokol-odin bindings `ae94aa5` track), verifies
   the sha256
   (`3e5a1b365cd221a8bd386a472cc9450eb7a0a6e93ce9a7fe6f86f8eb07a785c9`),
   and extracts the five headers into `third_party/sokol-c/` plus a
   `SOURCE_COMMIT` marker. The directory is gitignored.
2. **Dependency detection.** Checks for `cc`, `ar`, and the X11/GL dev
   symlinks (`libX11.so`, `libXi.so`, `libXcursor.so`, `libGL.so`) via
   `ldconfig -p`, printing package hints (Gentoo and Debian/Ubuntu) when
   something is missing.
3. **Static library build.** Generates one impl translation unit per
   library (`app`, `gfx`, `glue`, `log`), compiled with
   `-DSOKOL_GLCORE -DSOKOL_NO_ENTRY` in debug (`-g`) and release
   (`-O2 -DNDEBUG`) variants. Output mirrors the upstream sokol-odin
   layout: `third_party/sokol/sokol/<pkg>/sokol_<name>_linux_x64_gl_<variant>.a`
   (gitignored by the submodule). `SOKOL_NO_ENTRY` is required because we
   call `sapp.run()` from our own `main()`.
4. Paths are anchored to `#directory`, so the tool works from any CWD.

Notes:

- The Odin collection flag is `-collection:sokol=<abs path to
  third_party/sokol/sokol>`; imports use the collection syntax
  `import "sokol:app"` etc. `ols.json` was updated to match.
- Library selection: on Linux the bindings always link the GL variants
  (see the `foreign import` block in `sokol/app/app.odin`).
- Fetched sokol C code is zlib-licensed (floooh/sokol); the bindings
  directory keeps its own LICENSE.

## Validation run

Builds (all from the repository root):

```
odin run make.odin -file                    # debug build — ok
odin run make.odin -file -- --release       # release build — ok
odin check make.odin -file -vet -strict-style   # ok
```

Headless smoke tests (Xvfb, Mesa llvmpipe software GL):

```
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer
```

Output (debug build):

```
[sapp][warning] LINUX_X11_QUERY_SYSTEM_DPI_FAILED: failed to query system dpi value, assuming default 96.0
>> using GL backend
>> window initialized: 800x600 px, dpi_scale=1.00
>> autoquit after 10 frames
>> clean exit after 10 frames
exit_code=0
```

- The DPI warning is expected under Xvfb (no system DPI setting) and is a
  warning, not a failure.
- Release binary smoke test with 5 frames: clean exit 0.
- Normal mode (no env var) starts and keeps running until killed.
- No tracking-allocator leaks reported on shutdown.
- Rebuilds are idempotent: fetch and library compilation are skipped when
  outputs already exist.

## Platform status (honest)

| Platform        | Status                                            |
| --------------- | ------------------------------------------------- |
| Linux/X11       | Builds; window creation, GL rendering, clean shutdown validated headless (Xvfb + llvmpipe). Not yet run on a real desktop session. |
| Linux/Wayland   | Deferred by decision (2026-11-12).                |
| Windows         | Deferred by decision (2026-11-12).                |
| Other POSIX     | Untouched; make.odin prints a note that Sokol setup is Linux-only. |

## Open follow-ups

- Run the window once on a real X11 desktop to confirm visual output and
  ESC handling (implemented, untested there).
- `M05.01` will revisit shader tooling pins (`glslc` is present on this
  machine but not yet recorded as a dependency pin).
- Record the fetched-sokol provenance note in the compatibility inventory
  (`M00.09`).
