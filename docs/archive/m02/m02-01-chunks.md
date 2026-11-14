## M02.01 done (2026-11-12 session)

Immutable backing chunks (`docs/notes/m02-01-chunks.md`) — the SPECS.md §7.1
ByteStore layer, the foundation the rest of M02 builds on:

- New backend-free `src/core/chunk`: `Store` owning immutable,
  content-interned (hash-consed) byte chunks with stable `Chunk_ID`s.
  `insert` splits input into `chunk_size` chunks (overflow-free) and
  returns the id list (caller-owned); `data` returns borrowed views
  stable for the store's lifetime; `destroy` releases everything
  (arena-compatible no-op frees). Interning is a hand-rolled
  open-addressing table (load ≤ 3/4, `h|1` hashes, byte-compare
  collision resolution) — the pinned Odin has **no `core:map`**.
  Allocation failures surface as `.Resource_Limit` and leave the store
  consistent; error messages use the caller's allocator, never the
  store's.
- `tests/unit/chunk` added (9 tests): split/round-trip, dedup across
  and within inserts, empty/nil edges, view stability across table
  growth, constant-hash collision path, buffer-arena allocation-failure
  injection, growing-arena end-to-end reclaim, and a 300-step seeded
  differential property against a linear-scan reference model.
- Validated: 9/9 chunk tests leak-free (×5, no flake); full suite via
  `odin run make.odin -file -- test` (all packages clean); debug/release
  builds; Xvfb release smoke (exit 0, clean lifecycle); `-no-crt`
  Windows cross-build of a throwaway consumer + Wine 11 run (multibyte
  round-trip, dedup, exit 0). No product consumer yet (M02.02 wires the
  rope builder) — matches the M01.05 queue precedent.

