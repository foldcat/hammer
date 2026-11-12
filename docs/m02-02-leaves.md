# M02.02 — Leaves, metrics, and range iteration

Session doc for `src/core/rope` (2026-11-12), the second layer of the
persistent piece-rope (SPECS.md §7.1: Piece / Leaf / local metrics /
range iteration). M02.03 (balancing/persistent roots) builds the tree
on this layer.

## Design

```text
Piece        store_id (chunk.Chunk_ID) + byte_start + byte_length
Leaf         pool-allocated: <= 8 inline pieces + local Metrics
Sequence     ordered ^Leaf list + total Metrics (the M02.02 flat shape)
Metrics      byte_count, scalar_count, lf_count, lone_cr_count, Boundary
Boundary     leading_continuations, tail_expects, starts_with_lf, ends_with_cr
Span_Iter    stateless piece-wise walker over a byte range
```

- **Leaves in a pool** (the `core:container/pool` suggestion): `Leaf`
  has an intrusive `link: ^Leaf` field (`pool.init(&p, "link")`); the
  pool is virtual-arena backed, libc-free (`core:sync` +
  `core:mem/virtual` only), returns stable pointers, and `destroy`
  releases its storage wholesale. Fixed piece capacity (8) keeps every
  leaf one size. Leaves hold no nested allocations. The leaf-pointer
  list uses the caller-provided allocator; error messages too.
- **Leaf closing policy.** A leaf closes when it is full by piece count
  or when the next piece would exceed `target_leaf_bytes` (default
  16 KiB); an oversized single piece gets its own leaf.
- **Metrics and boundaries** (SPECS.md §7.2). `metrics_of` decodes a
  standalone byte run; `combine` merges adjacent runs exactly:
  - *Split multi-byte scalars*: a pending tail (`tail_expects`
    continuations still needed) merges with the right run's leading
    continuations; `scalar_count` subtracts the consumed count.
  - *Tail carry*: if the right run is entirely continuation bytes and
    the pending scalar still needs more, the merged tail carries over
    as `a.tail_expects - b.leading_continuations` (guarded against
    underflow). This case was caught by the randomized differential
    test, not by inspection.
  - *CRLF across a boundary*: `lone_cr_count` counts '\r' not followed
    by '\n'; a trailing '\r' is provisional and `combine` subtracts it
    when the right run starts with '\n'. `line_break_count(m)` =
    `lf_count + lone_cr_count`.
  - Grapheme counts deliberately absent (SPECS.md §7.2). The scalar
    count is a deterministic *counting model* (lead C2..DF/E0..EF/
    F0..F4 + continuations = 1 scalar; every other byte = 1), **not**
    full Unicode validation — that is M03.03/M10.01's job, which must
    keep this counting contract in sync.
- **Range reads never flatten** (SPECS.md §7.6): `read` fills a caller
  buffer (partial fills loop with an advanced range), `read_all`
  allocates the exact range, and `Span_Iter` yields borrowed slices of
  immutable chunk storage piece by piece. Ranges outside
  [0, byte_count] are `.Invalid_Input`; piece validation (unknown id,
  non-positive length, overrun) is `.Invalid_Input` via the new
  non-asserting `chunk.lookup` (M02.01 prerequisite fix).
- **Ownership/failure.** `sequence_destroy` drops the leaf list and the
  pool (arena-compatible no-op frees). Allocation failures
  (`.Resource_Limit`) leave the sequence consistent; error messages
  always use the caller allocator, never the sequence's own.
- **Backend-free**, builds under `-no-crt`.

## Validation run (all commands executed this session)

```text
odin check src/core/rope -no-entry-point -vet          -> clean
odin test tests/unit/rope -vet -collection:hammer=src -> 11/11,
    leak-checked, repeated 5x — no flake
odin run make.odin -file -- test                        -> all packages
    (errs 6, logging 5, lifecycle 5, platform 0 procs, config 14,
    coords 8, input 6, queue 6, layout 6, chunk 9, rope 11 = 76),
    leak-checked
odin run make.odin -file -- build && -- build --release -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)          -> exit 0, no
    PANIC/ERROR lines
Windows -no-crt check: throwaway consumer (/tmp/opencode/rcheck)
    built with the M02.01 cross flags -> runs under Wine 11:
    multibyte+CRLF content split across 4-byte chunks round-trips
    (24 bytes, 14 scalars, 2 breaks, 2 leaves), "ok", exit 0
```

Test coverage (`tests/unit/rope`): metrics_of hand-checked cases
(ASCII/LF, multibyte, CRLF, lone CR, invalid bytes, truncated tails,
empty); combine split-invariance over every split point of tricky
strings (including invalid lead sequences); tail-carry and broken-
completion merges; append+flatten; leaf splitting by piece count and
byte bound with per-leaf metrics recomputation; partial-read loops;
span iteration; range and piece validation errors; growing-arena
lifetime; buffer-arena allocation-failure injection; and a 300-step
seeded differential property (xorshift64, chunk size 5, 24-byte
leaves) comparing — after every append — the folded metrics against
both `metrics_of` of the flattened reference *and an independent
oracle implementation of the counting policy*, plus random whole/
partial/span range reads every 10 steps.

## Traps found (recorded for later tasks)

1. **The pinned `core:container/pool` requires an intrusive link field**
   (`pool.init(&p, "link")`, field must be `^T`), returns errors from
   `init`/`get` (`@(require_results)`), zeroes elements on `put`, and —
   importantly — **manages its own virtual arena**: pool memory is not
   visible to the caller's allocator, so tracking-allocator leak checks
   do not cover it; `pool.destroy` releases it. `destroy` drops
   outstanding elements wholesale (no puts needed). Default block size
   is 1 GiB *reserved* (growing arena commits on demand).
2. **`combine`'s tail-carry case**: when the right run is entirely
   continuation bytes merging into the left run's pending multi-byte
   scalar, the merged `tail_expects` must carry over as
   `a.tail_expects - b.leading_continuations` — and the branch needs a
   `b_lead < a_tail` guard or u8 subtraction underflows. Missed by
   inspection; caught by the randomized differential test.
3. **Shared-bug blindness**: a differential check comparing the folded
   metrics against `metrics_of` of the flattened text cannot catch a
   policy bug shared by both sides (`metrics_of` originally forgot to
   count `'\n'` as a scalar). Text-model tests need a *second,
   independent implementation* of the counting policy as an oracle —
   and hand-checked unit expectations.
4. **`\r\n` counting**: breaks = LF + lone-CR; a lone CR is a CR not
   followed by LF, and a trailing CR is provisional until `combine`
   sees the next run's `starts_with_lf`. `lf_count` and
   `line_break_count` are different metrics (SPECS.md §7.2) — do not
   fold CRLF into lf_count.
5. **The scalar counting model is not validation**: it accepts
   overlong/surrogate/out-of-range sequences as one scalar each for
   counting purposes. M03.03 (codecs) and M10.01 (chunk-safe decoder)
   own real validation and must stay consistent with this contract.
6. **Pool reuse vs persistence**: `pool.put` recycles a leaf for the
   next `get`. M02.03's persistent roots share leaves across versions —
   a leaf must never be `put` while any root (including historical
   undo roots) references it. Retain-and-prune policy lands with
   M02.03/M02.07.
7. Carried from M02.01: no `core:map`; `delete` on dynamic arrays takes
   no allocator; xorshift64 for test randomness; `-no-entry-point` for
   library `odin check`; Windows cross flags + `ODIN_LLD_PATH`.

## Platform status

| Platform | Status |
| -------- | ------ |
| Linux    | tested: 11/11 unit tests leak-free (incl. failure injection + dual-oracle differential), product builds/smoke unaffected |
| Windows  | implemented and cross-built (`-no-crt`) + run under Wine 11 (console consumer, exit 0); not tested on real Windows hardware |

No product consumer yet (M02.05's buffer registry wires the rope into
the editor); matches the M01.05/M02.01 precedent.

## Follow-ups (not part of M02.02)

- M02.03: internal nodes, balancing, persistent root updates — the
  `Sequence` is the flat leaf string today; the tree wraps or replaces
  it, reusing `combine`, leaves, and span iteration.
- `Sequence` per-append leaf closing assumes append-only growth;
  M02.03's splice operations split/merge leaves in place.
- Real-Windows runtime validation remains the standing D-02 follow-up.

## Next task

M02.03 — Balancing and persistent root updates.
