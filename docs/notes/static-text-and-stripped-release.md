# Static text stack and stripped release binaries

**Status:** done; Linux release builds link HarfBuzz, fontconfig, FreeType, and
ICU statically and strip the binary. Debug builds and all test targets keep the
dynamic `system:<lib>` linkages.

## Why

Distributed `hammer` binaries failed at load time on machines whose system text
libraries differed from the build machine, e.g. `./hammer: symbol lookup error:
undefined symbol: ubrk_close`, or "libharfbuzz not found". The text stack
(ICU, HarfBuzz, FreeType, fontconfig) was dynamically linked, so the product
depended on a matching shared library at run time.

## What changed

Release-only, Linux-only:

- The four bindings (`src/text/{icu,harfbuzz,freetype,fontconfig}`) select their
  linkage with a build define:
  `STATIC_TEXT :: #config(HAMMER_STATIC_TEXT, false)`. When set they link a
  staged archive `../../../build/static/lib<name>.a` instead of `system:<lib>`.
- `make.odin`'s `static_text_flags()` stages/builds the archives into
  `build/static` and returns the linker flags; the release build appends
  `-define:HAMMER_STATIC_TEXT=true` plus a single merged `-extra-linker-flags`
  value (strip + static group).
- HarfBuzz and fontconfig have no system static archives, so they are vendored:
  downloaded at pinned tags (`12.3.2`, `2.18.3`), sha256-verified, and built
  with meson+ninja into `build/` (gitignored). HarfBuzz is built with every
  optional backend disabled except FreeType; fontconfig uses the expat XML
  backend and is configured with the system runtime paths
  (`/etc/fonts/fonts.conf`, `/etc/fonts/conf.d`, `/var/cache/fontconfig`) so it
  reads the machine's normal font configuration.
- FreeType and ICU use the system static archives (`USE=static-libs`), staged
  into `build/static` by symlink.
- The archives are linked as a single `--start-group`/`--end-group` group
  because HarfBuzz and fontconfig both depend on FreeType, and Odin emits
  foreign-import libraries in a fixed order that does not honor that
  dependency. The dynamic closure after the group is
  `-lexpat -lbz2 -lpng16 -lz -lstdc++` (expat for fontconfig, bz2/png/z for
  FreeType, libstdc++ for ICU's C++ ABI).
- The release build strips the symbol table and debug sections via `-Wl,-s`.

## Tradeoffs and limits

- The release binary grows to ~39 MB, mostly the ~33 MB `libicudata.a` Unicode
  data baked in.
- Low-level transitive deps (expat, bz2, png16, z, libstdc++) remain dynamic.
  They are universal and ABI-stable, unlike the version-fragile text stack.
- The vendored HarfBuzz build disables glib/graphite2/icu/pcre2, so its static
  closure is just FreeType. The hand-written bindings only use the core shaping
  and hb-ft entry points, so this is sufficient.
- Static linking is release-only: `static_text_flags()` runs only in the
  release case, so debug builds stay dynamic and iterate faster (no 39 MB link
  and no vendored-build step).
- If any piece is missing (no system static FreeType/ICU, no meson/ninja, or a
  failed vendored build), the release build falls back to dynamic linking with a
  `[Setup] ... linking text dependencies dynamically` log line rather than
  failing.

## Validation

```text
odin run make.odin -file -- --release
    -> built; ldd shows no libicuuc/libicudata/libharfbuzz/libfreetype/libfontconfig
    -> file reports "stripped"; no .symtab/.debug_* sections
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> 10-frame render/shutdown smoke test exited 0; fonts/glyph cache active,
       no fontconfig config error
odin run make.odin -file
    -> debug build links the text stack dynamically (release-only static)
odin run make.odin -file -- text-test
    -> 40/40 tests passed (dynamic fallback path)
odin run make.odin -file -- test
    -> full core unit suite passed (dynamic fallback path)
```
