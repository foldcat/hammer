## Allocator migration done (2026-11-12 session)

Owner-directed refactor (`docs/m01-alloc-arenas.md`): the panic
allocator previously installed as `context.allocator` was replaced with
explicit arenas per AGENTS.md §10.5:

- `src/main.odin` owns two `core:mem/virtual` arenas: `perm` (whole
  program: logging sinks, errors, config-derived strings — one
  `free_all` at the end of main) and `temp` (frame scratch, installed
  as `context.temp_allocator`, reset at the end of every frame).
  `permanent()` returns the panic allocator until `init_arenas`
  succeeds, so an allocation before arena setup is a loud bug.
- Call sites now pass explicit allocators (`logging.init`,
  `config.describe`); core packages were already backend-free with
  explicit allocator parameters and are unchanged. No spike touched.
- New `test_arena_allocator_end_to_end` (tests/unit/config): resolve +
  errs + describe through one arena, single `free_all` reclaims all.
- Validated: 31/31 unit tests, debug/release Xvfb smokes (exit 0),
  panic path (exit 132, `[PANIC ]` logged), console-only mode, Windows
  cross-build + Wine 11 smoke under `-no-crt` (exit 0). Real desktop
  and real Windows remain the recorded follow-ups.

