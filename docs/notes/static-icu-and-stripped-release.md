# Static ICU linking and stripped release binaries

**Status:** done; Linux release and debug product builds link ICU statically,
the release binary is stripped, and the core/text test targets still link the
text dependencies dynamically.

## Why

Distributed `hammer` binaries failed at load time on machines whose system ICU
differed from the build machine, e.g. `./hammer: symbol lookup error: undefined
symbol: ubrk_close`. The text stack (ICU, HarfBuzz, FreeType, fontconfig) was
dynamically linked via `foreign import "system:<lib>"`, so the product depended
on a matching shared library at run time.

## What changed

- `src/text/icu/icu.odin` now selects its linkage with a `#config`:
  `STATIC_ICU :: #config(HAMMER_STATIC_ICU, false)`. When the define is set the
  bindings link the staged static archives instead of `system:icuuc`:
  - `../../../build/static/libicuuc.a`
  - `../../../build/static/libicudata.a`
  - `system:stdc++` (ICU is built as C++; the static archives reference the C++
    runtime ABI — vtables, `operator delete`). libstdc++ stays dynamic.
- `make.odin` gained `static_icu_flags()`, which locates the ICU libdir via
  `pkg-config --variable=libdir icu-uc`, checks that `libicuuc.a` and
  `libicudata.a` exist, and symlinks them into `build/static` (gitignored). It
  returns `-define:HAMMER_STATIC_ICU=true`, which the product build appends. If
  the archives are missing (e.g. an ICU built without `USE=static-libs`), it
  returns "" and the bindings fall back to dynamic linking.
- The release build appends `RELEASE_LD_FLAGS` (`-extra-linker-flags:-Wl,-s`),
  which strips the symbol table and debug sections (and therefore the embedded
  source-file and compilation-directory paths) from the shipped binary. Debug
  builds are unchanged and keep debug info.

## Tradeoffs and limits

- Static ICU bakes the ~33 MB Unicode data into the binary; the release binary
  grows to roughly 36 MB. This is the expected cost of `libicudata.a`.
- HarfBuzz, FreeType, and fontconfig remain dynamically linked. Their static
  archives are not installed on the reference system, and HarfBuzz's static
  closure (glib, graphite2, pcre2, ...) has not been audited. `static_icu_flags`
  is deliberately ICU-only for now; extending it to the other three requires
  enabling their `static-libs` USE flags and auditing/linking each transitive
  closure.
- The `text-test` and core `test` targets do not pass `HAMMER_STATIC_ICU`, so
  they continue to exercise the dynamic linkage path (correct for a dev
  machine).

## Validation

```text
odin run make.odin -file -- --release
    -> built; ldd shows no libicuuc/libicudata (only libstdc++ for the C++ ABI)
    -> file reports "stripped"; no .symtab/.debug_* sections
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> 10-frame render/shutdown smoke test exited 0
odin run make.odin -file -- text-test
    -> 40/40 tests passed (dynamic fallback path)
odin run make.odin -file -- test
    -> full core unit suite passed (dynamic fallback path)
```
