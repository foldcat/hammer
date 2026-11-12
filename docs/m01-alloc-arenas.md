# Allocator migration — arena-backed product allocation

**Status:** done (Linux/X11 validated headless; Windows cross-build +
Wine 11 smoke validated). This is an owner-directed refactor
(AGENTS.md §10.5), not a milestone task.

The product previously ran every allocation through a
`mem.Tracking_Allocator` and reported leaks at exit. The owner then
replaced `context.allocator` with a panic allocator to discourage
unmanaged allocation; this session routes all product allocations
through explicit arenas instead.

## Allocation layout (src/main.odin)

| Allocator                       | Backing                     | Lifetime                          | Reset point              |
| ------------------------------- | --------------------------- | --------------------------------- | ------------------------ |
| `perm` (permanent arena)        | `core:mem/virtual`, growing | whole program (log sinks, errors, config-derived strings) | never — one `free_all` at the end of `main` |
| `temp` (frame-scratch arena)    | `core:mem/virtual`, growing | one frame (plus startup scratch)  | end of every `frame` callback |

- `app_context()` installs `permanent()` as `context.allocator` and the
  frame arena as `context.temp_allocator` into every context (main +
  Sokol callbacks). Anything allocated through the ambient context is
  therefore arena-managed; the panic allocator remains only as a
  pre-init sentinel — `permanent()` returns it until `init_arenas` has
  succeeded, so an allocation before arena setup is a loud bug.
- `main` initializes both arenas first (`init_arenas`; failure is fatal,
  reported with raw `os.write_string` since formatting would allocate),
  then releases them in LIFO order: `app_destroy`, `logging.shutdown`,
  one `free_all(&perm)`, `destroy(&perm)`, `free_all(&temp)`,
  `destroy(&temp)`. Every arena is `free_all`ed and destroyed
  (AGENTS.md §10.5).
- Individual `delete`/`destroy` calls on arena-allocated data (e.g.
  `errs.destroy`, `logging.shutdown`) are safe no-ops: the arena
  allocator reports `.Mode_Not_Implemented` for `Free`, and everything
  is reclaimed by the single `free_all`.

## Call-site changes

- `logging.init(options, permanent())` — sink data and the cloned log
  path live for the whole program.
- `config.describe(cfg, context.temp_allocator)` — transient summary
  consumed by the next log call; the `defer delete` is gone.
- `errs.new`/`errs.newf` defaults resolve to the permanent arena via
  `context.allocator`; the lifecycle owns the message until exit.
- `frame` ends with `defer mem_virtual.arena_free_all(&temp)`: the
  documented scratch boundary. Log-line formatting (`fmt.tprintf` in
  `core:log`) and env reads land in the frame arena and are reclaimed
  there. Nothing borrows from `context.temp_allocator` across frames.
- `default_log_path` results are frame scratch; `logging.init` clones
  the path into the permanent arena before any reset.
- `src/core/config/resolve.odin` §`describe` comment updated: the
  product now has a frame arena, and `describe`'s default stays the
  caller-owned explicit allocator (results may need to outlive a frame
  reset).

Core packages (`errs`, `logging`, `lifecycle`, `config`) are unchanged:
they were already backend-free with explicit allocator parameters. No
spike was touched.

## New test

`tests/unit/config` gained `test_arena_allocator_end_to_end`: resolves a
config, creates an error, and describes the result all through one
`core:mem/virtual` arena, then proves a single `free_all` reclaims
everything (`arena.total_used == 0`).

## Validation run (all commands executed this session)

```text
odin run make.odin -file -- test                -> 31/31 unit tests pass
    (errs 6, logging 5, lifecycle 5, platform 1, config 14)
odin run make.odin -file                       -> stage + debug build, exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG=$S ./build/hammer
    -> exit 0; window, GL clear, clean arena-backed shutdown
odin run make.odin -file -- --release + smoke  -> exit 0
xvfb-run -a env HAMMER_TEST_PANIC=1 HAMMER_LOG=$S ./build/hammer
    -> exit 132; one [PANIC ] line in the log
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> console-only mode, exit 0
odin run make.odin -file -- windows            -> cross-build compiles
xvfb-run -a env WINEPREFIX=/tmp/opencode/wine-prefix
    HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine-vanilla-11.0 build/hammer.exe
    -> exit 0 under -no-crt -no-thread-local
```

## Follow-ups

- **Real desktop / real Windows** runtime validation remains the
  recorded D-02/M01 follow-up (unchanged from M01.01).
- **M01.05 workers:** each worker thread gets its own scratch arena
  (SPECS.md §17.4, AGENTS.md §10.5); do not share `temp` across threads.
  The frame arena is UI-thread-owned by convention; the virtual arena's
  internal mutex makes it safe but the reset boundary is not.
- **Bounded scratch:** the growing frame arena is reclaimed every frame
  but its first block stays reserved for the process lifetime; a
  per-frame high-water mark is worth measuring when M01.06 paints real
  rectangles.
