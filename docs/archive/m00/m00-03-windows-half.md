## M00.03 Windows half done (2026-11-12 session)

The D-02 Windows deferral was partially unblocked (owner installed
Wine 11 + mingw-w64 32/64) and the M00.03 Windows half executed:

- `odin run make.odin -file -- windows [--release]` cross-builds
  `build/hammer.exe` (`windows_amd64`, Sokol GL) on Linux: mingw-built
  Sokol libs, native lld-link (rust-lld shim / `ODIN_LLD_PATH`), mingw
  import libs as `build/windows-sdk/` `-windows-sdk-root`,
  `-no-crt -no-thread-local`.
- Validated headless under Wine 11 + Xvfb/llvmpipe: window create, GL
  clear, clean shutdown, exit 0 — debug and release.
- Traps + follow-ups (last-`/defaultlib`-only lld quirk, explicit
  Win32/UCRT lib inputs, D3D11 variant, real-Windows validation) are
  recorded in `docs/notes/m00-03-window.md` §Windows and
  `docs/notes/m00-09-decisions.md` §4/§5.

M01.01 remains the active task; the remaining Windows spike halves
(M00.04/05/07/08) stay deferred per D-02.

