# M03.03 — UTF-8/BOM/newline policy

Session doc for `src/core/filecodec` (2026-11-14): the allocation-free,
zero-copy codec boundary over the M03.02 `fileload.Loaded` chunk store
(SPECS.md §7.4). It defines what is editable UTF-8, retains original encoding
and BOM metadata, and records newline conventions without normalizing bytes.

## Design

```text
Decoded           metadata + status + first invalid sequence + raw/content streams
Metadata          Encoding + BOM + Newline + Newline_Counts
Status            Valid_UTF8 | Invalid_UTF8 | Unsupported_Encoding
Byte_Stream       borrowed chunk.Store + ordered ids + raw_start + length
Span_Iter         allocation-free borrowed-span walker over a Byte_Stream
```

- **Raw preservation.** `Decoded.raw` always covers every original file byte.
  Neither decoding nor newline inspection mutates or flattens the chunk store.
  A UTF-8 BOM is metadata rather than text, so `Decoded.content` starts after
  it; raw reconstruction still includes it. Content spans can feed the rope
  builder without a whole-file copy.
- **UTF-8 validation.** BOM-less input defaults to UTF-8; there is no encoding
  heuristic. The streaming validator accepts only shortest-form Unicode scalar
  encodings, rejects surrogates and values above U+10FFFF, and carries split
  sequences across chunks. Valid input agrees with the M02.02 scalar-counting
  model. Invalid input records the first malformed sequence's raw byte offset,
  malformed-prefix length, and reason. Bytes are never replaced.
- **Read-only boundary.** `can_edit` is true only for `.Valid_UTF8`.
  `.Invalid_UTF8` preserves the BOM-excluding bytes for M03.04's escaped
  rendering but cannot silently enter the editable UTF-8 model. UTF-16 LE/BE
  and UTF-32 LE/BE BOMs are recognized as `.Unsupported_Encoding`, retain raw
  bytes, have no decoded content stream, and remain read-only until deliberate
  conversion. UTF-32 is detected before its UTF-16 prefix. BOM-less UTF-16/32
  is not guessed.
- **Newlines.** Lone LF, CRLF, and lone CR are counted independently across
  chunk boundaries. `Newline` is `.None`, `.LF`, `.CRLF`, `.CR`, or `.Mixed`;
  mixed files are not flattened to a single convention. Unsupported encodings
  use `.Unknown`. Counts describe UTF-8/invalid-UTF-8 content, excluding a
  UTF-8 BOM. Actual newline bytes remain unchanged in both streams.
- **Ownership and bounds.** Decoding allocates nothing and performs one linear
  scan plus a bounded four-byte BOM prefix read. Streams and iterators borrow
  the Loaded store/id list: Loaded must stay fixed, alive, and unmutated until
  all borrowers are done. There is no asynchronous decode wrapper in this
  slice; a later worker integration must bound/cancel its own CPU scan.
- **Later consumers.** M03.04 owns escaped/replacement rendering, explicit
  invalid-byte offset maps, and deliberate conversion. M03.05 owns encoding a
  save snapshot and restoring BOM/newline metadata; M06/M07 wire buffer open.

## Validation run

```text
odin check src/core/filecodec -no-entry-point -vet         -> clean
odin test tests/unit/filecodec -vet -collection:hammer=src -> 10/10,
    leak-free (memory tracking enabled)
same targeted command, 10-run loop                         -> 10/10 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 10/10
odin run make.odin -file -- test                           -> 15 packages,
    152 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 ./build/hammer   -> exit 0,
    clean lifecycle shutdown
Windows -no-crt consumer (/tmp/hammer-m03-03-filecodec-consumer)
    built for windows_amd64 with the repository SDK/lld flags and run under
    Wine 11: one-byte-chunk UTF-8 BOM + mixed-newline decode, metadata,
    raw/content lengths, editability — "filecodec consumer: ok", exit 0
```

The 10 tests cover byte-exact raw/content streams; empty and BOM-only files;
UTF-8 BOM splits at every chunk size from 1–8; all newline styles, lone CR,
mixed sequences, and CRLF split across single-byte chunks; UTF-16/32 BOMs with
longest-prefix detection; valid UTF-8 scalar boundaries checked against both
`core:unicode/utf8` and M02.02 rope scalar counts; malformed leads,
continuations, overlong forms, surrogates, out-of-range scalars, and truncated
sequences; raw invalid offsets with a BOM; all 256 single-byte inputs; 1000
seeded pseudo-random inputs compared with the standard-library validator at
random chunk sizes; and a real `load_file`/`decode_loaded` round-trip using a
unique `os.make_directory_temp` sandbox.

An early fixture version used a fixed directory and failed on a repeat run
because `os.make_directory_all` reports `.Exist`. The fixture now creates a
unique system-temp directory per run and removes it; there is no dependency on
an agent-specific `/tmp/opencode` path.

## Traps found

1. **Fixed fixture directories are not repeatable sandboxes**: the pinned
   `os.make_directory_all` reports `.Exist` on a repeat run, and parallel test
   check/create sequences can race. Use `os.make_directory_temp` for a unique
   system-temp sandbox and remove it afterward; do not hardcode an
   agent-specific `/tmp/opencode` path.
2. **`-no-crt` is not an `odin check` flag** in the pinned compiler: use a
   purpose-built consumer with `odin build -target:windows_amd64 -no-crt` for
   the Windows CRT-free check. The consumer's enclosing `main` still cannot
   combine a trailing `os.exit` with defers (the M03.02 diverging-call trap).

## Platform status

- **Linux:** implemented and tested headlessly, including the real chunked
  loader integration, full core suite, debug/release builds, and Xvfb smoke.
- **Windows:** implemented and tested under Wine 11 with a `-no-crt`
  cross-built consumer. Real Windows remains unvalidated.
- **Product UI:** no consumer yet; buffer-open wiring remains M06/M07 work.

## Next task

M03.04 — explicit unsupported/invalid encoding behavior: retain the M03.03
read-only/raw-byte guarantees while adding clear escaped rendering, explicit
raw/display offset mapping, safe parser degradation, and deliberate conversion
for lossy encoding changes. Acceptance requires invalid bytes to survive the
open/display path without silent replacement and unsupported encodings to stay
read-only until the user explicitly converts them.
