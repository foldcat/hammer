# M03.04 — Explicit unsupported/invalid encoding behavior

Session doc for `src/core/filecodec` (2026-11-14): byte-preserving display
projections, explicit raw/display offset maps, parser degradation, and
deliberate conversion over the M03.03 `Decoded` boundary (SPECS.md §7.4).

## Design

```text
Display             owned valid-UTF-8 text + []Offset_Map + raw source bounds
Offset_Map          literal or `\xNN`-escaped raw/display spans
Parser_Mode         UTF8 | Plain_Text | Disabled
Conversion          owned UTF-8 text + lossy flag + replacement count
Conversion_Request  allow_lossy (required when malformed input is replaced)
```

- **Escaped display.** Valid UTF-8 content is copied byte-for-byte. Each
  malformed UTF-8 byte is displayed as lowercase `\xNN`; valid sequences around
  it remain unchanged. Unsupported UTF-16/32 input displays every raw byte,
  including its BOM, as `\xNN`. A UTF-8 BOM remains metadata and is excluded.
  Display text is always valid UTF-8 and is separate from the original bytes.
- **Explicit offsets.** `Offset_Map` coalesces literal and escaped runs. Raw
  offsets always refer to the complete original file, including any BOM.
  `raw_to_display` and `display_to_raw` accept positions at range ends;
  positions inside a four-byte escape have no raw-byte boundary and return
  `ok=false`. Empty and BOM-only content have a single end-position mapping.
- **Safe degradation.** Only `.Valid_UTF8` is editable and parser-eligible as
  UTF-8. Invalid UTF-8 remains read-only with `.Plain_Text`; unsupported
  encodings remain read-only with `.Disabled`. Escaped display bytes are never
  installed into the editable buffer by this package.
- **Deliberate conversion.** `convert_to_utf8` returns new owned storage and
  never mutates `Decoded` or `Loaded`. Valid UTF-8 is copied without its BOM.
  Well-formed UTF-16 LE/BE and UTF-32 LE/BE are decoded directly from chunks,
  including surrogate pairs, without an intermediate flattened source. Invalid
  UTF-8 and malformed wide input replace malformed units with U+FFFD only when
  `allow_lossy=true`; otherwise `.Lossy_Confirmation_Required` is returned
  before output allocation. Results report the replacement count and loss.
- **Ownership and bounds.** Display and conversion results record their
  allocator and have zero-safe destructors. Both use measure/fill passes,
  checked output-size arithmetic, and clean partial-allocation failure. Work
  and allocation are proportional to input/output size (display escapes are at
  most four bytes per source byte); no worker or cancellation wrapper is added.
  After construction, Display borrows no source storage. Conversion is likewise
  independent after success.

## Validation run

```text
odin check src/core/filecodec -no-entry-point -vet         -> clean
odin test tests/unit/filecodec -vet -collection:hammer=src -> 21/21,
    leak-free (memory tracking enabled)
same targeted command, 10-run loop                         -> 21/21 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 21/21
odin run make.odin -file -- test                           -> 15 packages,
    163 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
Windows -no-crt consumer (build/m03-04-consumer, generated)
    cross-built for windows_amd64 with the repository SDK/lld flags and run
    under Wine: invalid display/parser/loss refusal plus UTF-16LE surrogate
    conversion — "filecodec M03.04 consumer: ok", exit 0
```

The 11 new tests cover identity display and raw offsets with a BOM; invalid
escapes and every raw/display boundary at chunk sizes 1–5; escape-interior
rejection; unsupported byte views and parser/read-only policy; empty/BOM-only
mappings; lossless UTF-8 and UTF-16/32 conversion; deliberate-loss refusal for
invalid UTF-8, malformed surrogates, out-of-range UTF-32, and truncated units;
1000 seeded random inputs with valid-UTF-8 output checks; fixed-buffer
allocation failures; and a real one-byte-chunk `load_file` → display → refused
/confirmed conversion path in a unique system-temp sandbox. Every path checks
that the original raw stream remains byte-exact.

## Traps found

1. **Odin procedure parameters cannot be addressed as mutable locals**: the
   peeking byte cursor takes a value parameter, then makes an explicit local
   copy before passing its pointer to the advance helper.
2. **The pinned parser's bitwise-not spelling matters**: `~uint(0) >> 1` gives
   the native maximum signed integer for checked size arithmetic; `^uint(0)`
   is parsed as a pointer-type ambiguity.
3. **Short variable declarations require new names on the left**: after `ok`
   is already declared, `raw_offset, ok := ...` is a redeclaration error;
   declare the new variable separately and then use `=`.

## Platform status

- **Linux:** implemented and tested headlessly, including real chunked loading,
  allocation failure, full core suite, debug/release builds, and Xvfb smoke.
- **Windows:** implemented and tested under Wine with a `-no-crt` cross-built
  consumer. Real Windows remains unvalidated.
- **Product UI:** no consumer yet; buffer-open and actual rendering wiring are
  M06/M07 work. Save-time encoding and metadata transitions remain M03.05.

## Next task

M03.05 — temporary-write/replace save. Preserve raw/dirty state on every
failure, encode only from an explicit snapshot/policy, retain the original
encoding/BOM/newline metadata unless the user deliberately converted it, and
never save escaped display text as though it were source content.
