# M00.03 — Build/run a window (Linux/X11 and Windows/Wine)

**Status:** done (Linux/X11 validated headless; Windows cross-build
validated under Wine). See the Windows section for the 2026-11-12 unblock.

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

**Revised 2026-11-12 (same day, later session):** the owner installed
Wine 11 and the mingw-w64 cross toolchain (64- and 32-bit), satisfying
the toolchain half of the D-02 unblock conditions
(`docs/m00-09-decisions.md` §4). The M00.03 Windows half was therefore
unblocked and executed: the window now cross-builds from Linux and runs
under Wine. See the Windows section below. The Windows halves of
M00.04/M00.05/M00.07/M00.08 and the Windows CI runner remain deferred.

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

| Platform      | Status                                                                                                                                                    |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux/X11     | Builds; window creation, GL rendering, clean shutdown validated headless (Xvfb + llvmpipe). Not yet run on a real desktop session.                        |
| Linux/Wayland | Deferred by decision (2026-11-12).                                                                                                                        |
| Windows       | Cross-builds from Linux; window creation, GL rendering, clean shutdown validated under Wine 11 (Xvfb + llvmpipe). Not validated on real Windows hardware. |
| Other POSIX   | Untouched; make.odin prints a note that Sokol setup is Linux-only.                                                                                        |

## Windows cross-build (2026-11-12 session)

The Windows half of M00.03 is now done: `odin run make.odin -file -- windows`
cross-builds `build/hammer.exe` for `windows_amd64` on this Linux machine,
and the binary runs under Wine. This satisfies the toolchain half of the
D-02 unblock; real-Windows validation still needs a Windows CI runner.

### Toolchain

| Piece       | What is used on this machine                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| C cross-cc  | `x86_64-w64-mingw32-gcc` (mingw-w64 16, UCRT flavor) — builds the Sokol static libs                                                         |
| Archiver    | `x86_64-w64-mingw32-ar`                                                                                                                     |
| Linker      | a native `lld-link`: `~/.rustup/.../rust-lld -flavor link` via a generated `build/lld-link-shim`; or `ODIN_LLD_PATH`; or `lld-link` on PATH |
| System libs | mingw import libraries, symlinked as `.lib` names into `build/windows-sdk/` (the `-windows-sdk-root`)                                       |
| Runtime     | Wine 11 (`wine-vanilla-11.0` on this machine; no `wine` symlink exists)                                                                     |

### How it works

1. `setup_windows_sdk` mirrors every `lib*.a` in the mingw sysroot into
   `build/windows-sdk/` as `<name>.lib` symlinks (930 of them), plus
   `libgcc.a` → `libgcc.lib`. Odin's `-windows-sdk-root` scans this tree
   case-insensitively to resolve bare system library names, and lld-link
   resolves them through `/libpath`. A flat layout is sufficient; no MSVC
   SDK layout is required.
2. `build_sokol_libs_windows` compiles the pinned Sokol C sources with
   mingw (`-DSOKOL_GLCORE -DSOKOL_NO_ENTRY`) and archives them as
   `third_party/sokol/sokol/<pkg>/sokol_<pkg>_windows_x64_gl_<variant>.lib`
   — the exact names the sokol-odin bindings `foreign import` for
   `-define:SOKOL_USE_GL=true` (gitignored by the submodule).
3. The final link runs with `-target:windows_amd64 -linker:lld -no-crt
-no-thread-local` plus the Win32/UCRT libraries as **plain linker
   inputs** (`user32 kernel32 gdi32 shell32 ucrtbase libgcc mingwex`).

### Traps found (each verified, each owned)

- **`-windows-sdk-root:<dir>` is mandatory** for any windows-target
  executable build from Linux (Odin rejects the build otherwise). It
  accepts a flat directory of `.lib` files; the `/winsysroot` flag Odin
  adds is harmless with this layout.
- **The lld-link in use honors only the last `/defaultlib` argument**
  (verified with symbol-level tests: user32 symbols resolve or not
  depending on argument order, not on the set). System libraries are
  therefore passed as plain inputs, never as `/defaultlib`.
- **sokol C needs explicit Win32 imports**: a mingw build of sokol has no
  MSVC `#pragma comment(lib, ...)`, so `user32`/`kernel32`/`gdi32`/
  `shell32` must be added at final link. The needed set was derived from
  the undefined symbols of the compiled objects.
- **mingw UCRT CRT symbols**: sokol's `fputs`/`malloc`/`abort`/... resolve
  from `ucrtbase` (this mingw targets UCRT, confirmed by the
  `__imp___acrt_iob_func` reference), `___chkstk_ms` from `libgcc`,
  `_assert` from `mingwex`.
- **`-no-crt` requires `-no-thread-local`**, and Odin then provides
  `mainCRTStartup`, `_fltused`, and `_tls_index` itself. No MSVC CRT
  (libcmt) is needed or used.
- The Odin release bundles Windows-exe linkers (`bin/lld-link.exe`,
  `bin/radlink.exe`) intended to run through a Wine binfmt handler; none
  is registered on this machine, so a native lld-link is used instead.
- Only the **GL backend** is built/validated for Windows so far
  (`SOKOL_USE_GL=true`). The sokol Windows default is D3D11
  (`.lib` names `..._d3d11_...`, plus `d3d11`/`dxgi`/`d3dcompiler_47`
  imports); that variant is a follow-up.

### Validation run

Builds (repository root):

```
odin run make.odin -file -- windows           # debug cross-build — ok
odin run make.odin -file -- windows --release # release cross-build — ok
odin check make.odin -file -vet -strict-style # ok
```

Smoke tests (Wine 11, task-owned WINEPREFIX, Xvfb + Mesa llvmpipe):

```
xvfb-run -a env WINEPREFIX=/tmp/opencode/wine-prefix HAMMER_AUTOQUIT_FRAMES=10 wine-vanilla-11.0 build/hammer.exe
```

Output (debug build; release identical apart from frame count):

```
>> using GL backend
>> window initialized: 800x600 px, dpi_scale=1.00
>> autoquit after 10 frames
>> autoquit after 11 frames
>> clean exit after 11 frames
exit 0
```

- GL context comes up through Wine's `opengl32` → wined3d → llvmpipe under
  Xvfb; frames render and shutdown is clean in both build modes.
- `dpi_scale=1.00`: Wine reports the Windows-default 96 DPI (no
  LINUX_X11_QUERY_SYSTEM_DPI_FAILED warning, unlike the Linux/Xvfb run).
- The tracking-allocator leak report stays silent on shutdown.
- Wine prints harmless `_amdgpu_device_initialize`/`libEGL DRI3` lines on
  this host (no discrete GPU in the headless run); they do not affect the
  app.

Not validated (recorded honestly): real Windows hardware; the D3D11
backend variant; the ESC-close path (no input injection into Wine was
performed); `windows_386` (the pinned sokol-odin bindings only name
`windows_x64_*` libraries); a real GPU or real desktop DPI.

## Open follow-ups

- Run the window once on a real X11 desktop to confirm visual output and
  ESC handling (implemented, untested there).
- `M05.01` will revisit shader tooling pins (`glslc` is present on this
  machine but not yet recorded as a dependency pin).
- Record the fetched-sokol provenance note in the compatibility inventory
  (`M00.09`).
- Windows: build and validate the sokol **D3D11** variant (the product
  default on Windows) under Wine; validate on a real Windows machine/CI
  runner when available (see `docs/m00-09-decisions.md` §4).
