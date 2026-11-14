# M02.01 — Immutable backing chunks

Session doc for `src/core/chunk` (2026-11-12), the first layer of the
persistent piece-rope (SPECS.md §7.1: "ByteStore — immutable chunks /
private backing snapshots"). M02.02 (leaves/metrics/range iteration)
and M02.03 (balancing/persistent roots) build pieces on top of this
package.

## Design

```text
chunk.Store
  allocator        (from init; everything the store keeps)
  chunk_size       (target split size, from Options)
  hash             (content hash proc, default XXH64)
  chunks           [dynamic]chunk_header   id-1 index; data immutable
  total            bytes actually stored
  table            open-addressing intern table (parallel hash/id arrays)

chunk.Chunk_ID :: distinct u64   (0 = nil/empty)
chunk.insert(data, allocator) -> ([dynamic]Chunk_ID, errs.Error)
chunk.data(id) -> []byte         (borrowed, immutable, store-lifetime)
```

- **Splitting.** `insert` splits its input into `chunk_size`-byte chunks
  (last may be shorter; `(n-1)/size+1` chunks, no overflow) and returns
  the id list in order — concatenating `data(ids[i])` reproduces the
  input byte-for-byte. Empty input returns an empty list. This is the
  shape M02.02 turns into pieces and M03.02's chunked file loading
  feeds directly.
- **Interning (hash-consing).** Each split chunk is interned by content
  (XXH64, injectable `Options.hash`): byte-identical chunks share one
  allocation and one id. Because there is no `core:map` in the pinned
  Odin (dev-2026-11), the intern table is a small hand-rolled
  open-addressing table: parallel `hashes`/`ids` dynamic arrays,
  power-of-two capacity, linear probing, load factor ≤ 3/4, stored
  hashes are `h | 1` so zero marks empty slots, collisions resolved by
  byte comparison. Growth doubles the table (16 when empty) and
  rehashes; on failure the old table is untouched.
- **Immutability.** Published bytes never change and stay at a stable
  address for the store's lifetime; `data` views are borrowed. No
  refcounting in M02.01: chunks live until `destroy`; retention/budget
  policy is a later milestone concern (M02.08 benchmarks).
- **Ownership.** The store allocates everything it keeps (chunk data,
  index, intern table) from its `init` allocator; `destroy` frees each
  chunk and the arrays and resets to zero. With an arena allocator
  (`core:mem/virtual`, the product shape) the individual frees are
  no-ops and `free_all` reclaims — verified end to end. `insert`'s id
  list and error messages use the caller-provided allocator (never the
  store's), so they cannot fail together with the store.
- **Failure.** All allocation failures surface as `.Resource_Limit`;
  the store stays consistent, and chunks interned before a failed
  insert remain interned (a retry deduplicates onto them). `intern`
  returns raw `mem.Allocator_Error`; `insert` translates them into
  structured errors. Allocation-failure behavior is failure-injection
  tested with a fixed-size buffer arena.
- **Single owner.** Not thread-safe; one mutator thread (AGENTS.md
  §13). Chunk views may be read elsewhere while the owner does not
  call `destroy`.
- **Backend-free.** Imports only `core:` packages (`bytes`, `hash/xxhash`,
  `mem`, `base:runtime`) plus `core/errs` — no Sokol collection
  (SPECS.md §4.2), builds under `-no-crt`.

## Validation run (all commands executed this session)

```text
odin check src/core/chunk -no-entry-point -vet          -> clean
odin test tests/unit/chunk -vet -collection:hammer=src -> 9/9,
    leak-checked (tracking allocator), repeated 5x — no flake
odin run make.odin -file -- test                        -> all packages
    (errs 6, logging 5, lifecycle 5, platform 0 procs, config 14,
    coords 8, input 6, queue 6, layout 6, chunk 9), leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, clean
    lifecycle shutdown, no PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/cchunk)
    built with -target:windows_amd64 -linker:lld -no-crt
    -no-thread-local -windows-sdk-root:build/windows-sdk
    -extra-linker-flags:"/libpath:build/windows-sdk <product lib list
    + ntdll.lib bcrypt.lib>" -> runs under Wine 11: multibyte UTF-8
    round-trip 44/44, dedup ids reused, "ok", exit 0
```

Test coverage (`tests/unit/chunk`): split/round-trip incl. exact
multiples; interning dedup; dedup across inserts and within one insert;
empty/nil edge contracts; view stability across table growth; constant-
hash collision path (byte-compare lookup + dedup under full collision);
allocation-failure injection (fixed 4 KiB buffer arena → `.Resource_Limit`,
consistent bookkeeping, intact earlier chunks); growing-arena end-to-end
(`free_all` → `total_used == 0`); and a 300-step seeded differential
property (xorshift64) checking every returned id list against a trivial
linear-scan reference model plus full published-chunk equality.

## Traps found (recorded for later tasks)

1. **The pinned Odin (dev-2026-11) has no `core:map`.** The chunk
   store therefore hand-rolls its open-addressing intern table. Any
   later package needing a hash map (buffer registry in M02.05, finder
   indexes in M15, IPC tables in M18) must either build on this table
   pattern or vendor one deliberately — do not assume `core:map`.
2. **`delete(dynamic_array)` takes no allocator argument** in the
   pinned compiler (the array header records its allocator; the
   two-argument form is for maps).
3. **`xxhash.XXH64` also has a `seed` default parameter**, so its
   full proc type is `proc([]u8, u64) -> u64`; assigning it where a
   one-argument proc type is expected fails type-checking (and so does
   the ternary). Wrap it in a named one-argument proc.
4. **Core procs are not `"contextless"`** (`XXH64` is not marked
   contextless), so a hash proc type with a `"contextless"`
   requirement cannot call them — the store's `Hash_Proc` is a plain
   proc type.
5. **String literals cannot be `transmute`d directly** to `[]byte`
   (`transmute([]byte)"x"` rejects untyped expressions); the repo idiom
   is `transmute([]byte)variable` or `transmute([]byte)string("x")`.
6. **LCG low bits are periodic**: `state % 60` / `state % 38` on a
   power-of-two LCG cycles with tiny periods (the low 6 bits repeat
   every 64 steps), which turned a "random" differential stream into
   repeating content and broke a dedup-sensitive invariant. Use
   xorshift64 (or high bits) for test randomness.
7. **Test fillers must be distinct per iteration**: an all-zero
   filler deduplicates every insert to one chunk, silently defeating an
   exhaustion test.
8. **`odin check` on a library package needs `-no-entry-point`**;
   without it the tool demands a `main` procedure.
9. **Arena `free` is `.Mode_Not_Implemented`** (`core:mem/virtual`):
   individual frees against an arena are safe no-ops, but only
   `free_all` reclaims — and a **buffer arena's `arena_destroy` does
   not free the caller's buffer** (caller deletes it after destroy).
10. Carried from M01.05: Windows cross-linking needs `-linker:lld`,
    `-windows-sdk-root`, and the explicit import-lib list (plus
    `ntdll.lib`/`bcrypt.lib` for a console consumer), via
    `-extra-linker-flags`; `ODIN_LLD_PATH` must point at a native
    lld-link (the repo shim at `build/lld-link-shim` wraps rust-lld).

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 9/9 unit tests leak-free, arena + failure-injection paths, product builds unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (console consumer, exit 0); not tested on real Windows hardware |

The product (`src/main.odin`) does not consume this package yet — no
consumer exists until M02.02 wires the rope builder; this matches the
M01.05 queue precedent.

## Follow-ups (not part of M02.01)

- Chunk retention/budget policy (refcounting or store-wide pruning) —
  M02.08 benchmarks decide.
- `insert` error messages allocate from the caller's allocator; passing
  the store's own (failing) allocator there is a documented caller
  mistake, not a supported path.
- Real-Windows runtime validation remains the standing M02/D-02
  follow-up.

## Next task

M02.02 — Leaves, metrics, and range iteration over pieces
(`src/core/rope` or the package decision made there).
