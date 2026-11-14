## M03.01 done (2026-11-13 session)

Canonical file identity (`docs/m03-01-fileid.md`) — the SPECS.md §6.4
identity model and its validation as the M03 foundation:

- New backend-free `src/core/fileid`: `File_ID` (kind + hi/lo:
  Unix st_dev/st_ino, Windows zero-extended volume serial / 64-bit
  file index; `.None` is one canonical value — inode 0 and file index
  0 map to it, hi/lo ignored, never a dedup key), `id_equal` +
  `id_cmp` (total order, cmp == 0 iff equal), `File_Stamp`
  (version-validated identity: id + size + mtime, `make_stamp`
  validates only nsec — size/mtime pass through, negative mtimes
  valid), `stamp_status` (Unchanged/Changed/Replaced: identity
  difference → Replaced incl. cross-kind; either id `.None` →
  size+mtime best effort, never Replaced), `stamp_equal`, and the
  §6.4 `Case_Sensitivity`/`Symlink_Policy` tracked attributes. No
  file I/O — the stat/path adapters land with M03.02/M03.06.
- `tests/unit/fileid` added (8 tests): constructor mapping (incl.
  zero-dev/zero-serial non-invalidation), equality/order hand cases,
  stamp validation error paths, the full status decision table, and
  two seeded differentials (250-id order vs an independent array-key
  reference with antisymmetry + cmp/equal agreement + transitivity;
  1200-draw status vs an independently structured reference policy
  with reflexivity/symmetry/all-class coverage).
- Validated: 8/8 fileid tests leak-free (×10, no flake; also
  single-threaded); full suite via `odin run make.odin -file -- test`
  (123 tests, all 13 test-bearing packages clean); debug/release
  builds; Xvfb release smoke (exit 0, no PANIC/ERROR); `-no-crt`
  Windows cross-build of a throwaway consumer + Wine 11 run
  (constructors, none mapping, validation error path, all three
  status classes, exit 0). No product consumer yet (M03.02 wires the
  capture adapter).

