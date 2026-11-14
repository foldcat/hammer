# M03.01 — Canonical file identity

Session doc for `src/core/fileid` (2026-11-13): platform file identity
(device/inode on Unix, volume-serial/file-index on Windows) plus
version-validated identity (size + mtime) for external-change detection
(SPECS.md §6.4, §11.1 steps 2/8, §11.2). Headless, backend-free
(SPECS.md §4.2): there is no file I/O architecture yet, so this slice is
deliberately the identity **model and its validation** — the stat
capture adapters land with M03.02 (background loading) and M03.06
(disk-change detection), and canonical *path* resolution
(realpath / GetFinalPathNameByHandle) needs the same adapters.

## Design

```text
ID_Kind        None | Unix | Windows
File_ID        kind + hi + lo (u64)
                 Unix:    hi = st_dev, lo = st_ino
                 Windows: hi = volume serial (zero-extended u32),
                          lo = 64-bit file index
File_Stamp     id + size + mtime_sec + mtime_nsec
Stamp_Status   Unchanged | Changed | Replaced
Case_Sensitivity   Unknown | Case_Sensitive | Case_Insensitive
Symlink_Policy     Follow | Preserve_Link
```

- **`File_ID`** is the dedup key for the buffer registry (§6.4): every
  spelling of one file — `foo.c`, `./foo.c`, `/proj/foo.c`, a symlink
  to it, a hard link to it — shares one id. Hard links need no special
  handling: the identity is the inode/file index, so they *are* the
  same identity. `id_cmp` imposes a total order (`.None` first, then
  kind, then hi, then lo) pinned to satisfy `cmp == 0` iff `equal`,
  so sort-based registries are safe.
- **`.None` is one canonical value.** An id with kind `.None` ignores
  `hi`/`lo` in every comparison: `unix_id` maps inode 0 to `.None`
  (POSIX: st_ino == 0 is never a valid file), `windows_id` maps file
  index 0 to `.None` (no stable identity on that volume). Callers must
  never use `.None` as a registry key — two unidentifiable files would
  collide; the M03.06 capture layer falls back to path identity there.
  `st_dev == 0` and volume serial 0 are *not* invalidated (they occur
  on anonymous devices and real volumes); only the inode/index zero
  convention is encoded.
- **`File_Stamp`** is the versioned identity: what a buffer records at
  load and after each successful save (§11.1 step 8), and what a fresh
  stat produces to validate against (§11.1 step 2). `make_stamp`
  validates only `mtime_nsec` (`.Invalid_Input` outside
  `[0, 1_000_000_000)`); size and mtime pass through unconstrained
  (any u64 / any i64 — negative mtimes are valid on FAT). The version
  is size + mtime only, no ctime: ctime flags metadata touches that do
  not change content, and the id already catches replacement.
- **`stamp_status`** is the classification the conflict machinery
  consumes:
  1. both identities available and differing → `.Replaced` (including
     cross-kind ids, which never compare equal);
  2. same identity → size+mtime equal → `.Unchanged`, else `.Changed`;
  3. either identity `.None` → identity unverifiable → size+mtime
     only, never `.Replaced`. Documented best effort: a
     same-size-same-mtime replacement is undetectable without
     identity, and what `.Unchanged` is worth on such filesystems is
     the caller's (M03.06) policy decision.
- **Case/symlink attributes** (§6.4) are defined as tracked enums only:
  `.Unknown` is the honest default for case behavior (never assume Unix
  is case-sensitive or Windows case-insensitive), and `Symlink_Policy`
  records whether the buffer's identity is the target's (`.Follow`) or
  the link's (`.Preserve_Link`). No path machinery here — resolution is
  I/O and lands with the adapters; save-through-symlink semantics are
  M03.05's decision, not implied by the enum.

Nothing allocates except the `make_stamp` failure message (caller
allocator); no assertion anywhere (all inputs are external data,
AGENTS.md §11.2).

## Validation run (all commands executed this session)

```text
odin check src/core/fileid -no-entry-point -vet        -> clean
odin test tests/unit/fileid -vet -collection:hammer=src -> 8/8
    leak-free (memory tracking on), 7 ms
flake loop ×10 (same command)                          -> no flake
single-threaded (-define:ODIN_TEST_THREADS=1)          -> 8/8
odin run make.odin -file -- test                       -> 13 packages,
    123 tests (8 new), exit 0, leak-free
odin run make.odin -file -- build                      -> exit 0
odin run make.odin -file -- --release                  -> exit 0
Xvfb release smoke (HAMMER_AUTOQUIT_FRAMES=10)         -> exit 0, clean
    lifecycle shutdown, no PANIC/ERROR lines
Windows -no-crt check: throwaway consumer
    (/tmp/opencode/m03-01-win-consumer, not committed) built with
    -target:windows_amd64 -linker:lld -no-crt
    -no-thread-local -windows-sdk-root:build/windows-sdk
    -extra-linker-flags:"/libpath:build/windows-sdk <product lib list
    + ntdll.lib bcrypt.lib>" -> runs under Wine 11: constructors,
    none mapping, equality/order, stamp validation (error path
    included), all three status classes, "ok", exit 0
```

Test coverage (`tests/unit/fileid`, 8 tests): constructor mapping incl.
the inode-0/file-index-0 none conventions and the zero-dev/zero-serial
non-invalidation; equality/total-order hand cases + antisymmetry and
cmp==0-iff-equal over every ordered pair; stamp validation boundaries
and both error paths (describe/destroy, leak-free); the full
hand-computed status decision table (every version field, every way
identity can differ, none-on-either-side, garbage-hi/lo none); stamp
equality; and two seeded differentials — a 250-id order differential
(id_cmp vs an independent array-key reference + antisymmetry +
cmp/equal agreement + transitivity over consecutive triples) and a
1200-draw status differential (random stamps with 0..6 random field
mutations vs an independently structured reference policy + reflexivity
+ symmetry + coverage of all three classes).

## Traps found (recorded for later tasks)

1. **Odin rejects `for i in ...` when `i` is unused** ("declared but
   not used"): the two generation loops in the differentials needed
   `for _ in 0 ..< n`. (Unlike some languages, unused *loop* variables
   are an error, not a warning.)
2. Carried and confirmed this session: xorshift64 for test randomness
   (M02.01); bind slice literals before ranging (M01.05); fresh names
   per `:=` declaration (M02.04); no local type declarations (M02.06);
   the reference model is an independent implementation of the same
   policy (M02.02 shared-bug blindness); Windows cross-linking needs
   `-linker:lld` + `-windows-sdk-root` + the explicit import-lib list
   plus `ntdll.lib`/`bcrypt.lib` for a console consumer (M02.01);
   `odin check` on a library package needs `-no-entry-point` (M02.01);
   `-define:ODIN_TEST_THREADS=1` to separate races from logic bugs
   (M02.03).

## Platform status

- **Linux:** implemented and tested (model + policy only — no stat
  integration exists yet; the model is exercised headlessly and under
  the Wine-run Windows build).
- **Windows:** implemented and tested at the model level (`-no-crt`
  cross-build + Wine 11 consumer run, exit 0). No real NTFS/FAT volume
  behavior is exercised — the `BY_HANDLE_FILE_INFORMATION` capture
  adapter is M03.02/M03.06 work.
- **Filesystem behaviors:** none tested yet (case sensitivity probing,
  symlink resolution, identity-less filesystems) — those need real
  capture adapters, by design of this slice.

## Follow-ups (not part of M03.01)

- M03.02: stat capture (dev/ino on Linux, `BY_HANDLE_FILE_INFORMATION`
  on Windows) feeding `unix_id`/`windows_id`/`make_stamp`; canonical
  path resolution; volume case-sensitivity probing feeding
  `Case_Sensitivity`.
- M03.06: wire `stamp_status` into disk-change conflict detection
  (§11.2) and the §11.1 pre-save validation step; decide the
  identity-less-filesystem policy for `.Unchanged`.
- M03.05: symlink save semantics for `Symlink_Policy`.

## Next task

M03.02 — background chunked loading (NEXT.md): the read/capture adapter
that produces `File_ID`/`File_Stamp` values from real files and feeds
chunked content into the M02 chunk store, with the identity captured at
load time. Acceptance: headless core tests, captured stamps match
fresh stats, `.None` identity handling per this doc.
