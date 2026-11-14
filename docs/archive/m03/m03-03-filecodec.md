## M03.03 done (2026-11-14 session)

UTF-8/BOM/newline policy (`docs/m03-03-filecodec.md`) — a backend-free,
allocation-free `src/core/filecodec` over M03.02 `Loaded` chunks:

- `Decoded` retains byte-exact `raw` and BOM-excluding `content` borrowed
  streams, original encoding/BOM/newline metadata, an explicit status, and the
  first invalid UTF-8 sequence's raw offset/length/reason. Strict streaming
  validation rejects overlong forms, surrogates, out-of-range scalars, bad
  continuations, and truncation across chunks. Only valid UTF-8 is editable;
  invalid UTF-8 and recognized UTF-16/32 BOMs stay read-only without byte
  replacement or heuristic detection. LF, CRLF, lone CR, and mixed conventions
  are counted across boundaries and never normalized. `Span_Iter` exposes the
  content without flattening it.
- `tests/unit/filecodec` added (10 tests): every BOM split size, newline table,
  unsupported Unicode BOMs, scalar boundary agreement with the M02 rope and
  standard UTF-8 library, malformed-sequence table, all 256 single bytes,
  1000 seeded random differential cases at random chunk sizes, raw invalid
  offsets, and a real one-byte-chunk `load_file` round-trip in a unique
  system-temp sandbox.
- Validated: targeted 10/10 leak-free (×10 and single-threaded); full suite
  152 tests clean across 15 packages; debug/release builds; Xvfb release
  smoke; `-no-crt` Windows consumer + Wine 11 run (split BOM, mixed newlines,
  raw/content lengths, editability — exit 0). No product consumer yet
  (M06/M07); escaped rendering/offset maps/conversion are M03.04 and saving is
  M03.05.

Required reading for new code in `src/`: the traps in
`docs/m01-02-config.md` §Traps, `docs/m01-03-coords.md` §Traps,
`docs/m01-04-input.md` §Traps, `docs/m01-05-queue.md` §Traps,
`docs/m01-06-render.md` §Traps, `docs/m02-01-chunks.md` §Traps,
`docs/m02-02-leaves.md` §Traps, `docs/m02-03-tree.md` §Traps,
`docs/m02-04-coords.md` §Traps, `docs/m02-05-transactions.md` §Traps,
`docs/m02-06-anchors.md` §Traps, `docs/m02-07-undo.md` §Traps,
`docs/m02-08-benchmarks.md` §Traps, `docs/m03-01-fileid.md`
§Traps, `docs/m03-02-fileload.md` §Traps, and
`docs/m03-03-filecodec.md` §Traps (never copy a
Doc/Tree/Store; reference models replay the applied order;
empty-range replace is a pure insert; no local type declarations; no
`core:map`; a no-op apply creates no node; `make` with a length
pre-fills; `delete` on a `[]byte` goes through `context.allocator`;
`odin test pkg1 pkg2` runs only the first package; xorshift64 seeds,
no flakes; `.Non_Blocking` breaks Windows `os.read`; `time.Time` is a
struct — `time.to_unix_nanoseconds`; a `defer` in a scope ending in a
diverging call is rejected; `os.write_entire_file` truncates before
writing — use temp+rename for atomic-replace invariants).

