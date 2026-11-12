# M01.02 — Generated trusted configuration package

**Status:** done (Linux/X11 validated headless; Windows cross-build
validated under Wine 11). Real-desktop visual confirmation remains the
recorded M01 follow-up.

This task delivers the compiled configuration package (SPECS.md §18 M01
deliverables, SPECS.md §14 "Configuration and EditorConfig"): a trusted
user config is staged into a generated Odin package at build time and
compiled into the binary. Config edits change colors/font-size settings
after a rebuild — the M01 acceptance rule.

## What was built

| Piece | Responsibility |
| ----- | -------------- |
| `src/core/config/schema.odin` | The schema (SPECS.md §14.2 illustrative schema): `Theme` (10 RGBA colors), `Config` (`font_families`, `font_size_points`, `line_height`, `ligatures`, `theme`), `Resolved`, `Source` (Builtin/File), bounds, `parse_hex_color`, `validate`. Exported struct fields; backend-free. |
| `src/core/config/defaults.odin` | Built-in defaults: the modified oxocarbon theme from `colorscheme.yaml` (base00–base0F), the default font stack, 12 pt / 1.4. |
| `src/core/config/yaml.odin` | A minimal, strict YAML subset parser for the config schema (flat + one-level mappings, quoted/plain scalars, block and inline lists, comments, blank lines; tabs/anchors/deeper nesting rejected). No YAML dependency added (AGENTS.md §18). |
| `src/core/config/resolve.odin` | `resolve_from_yaml`/`resolve_from_path`: parse → build `Config` → fill defaults → validate → own the result (`resolved_destroy`). `builtin()`, `describe()`. |
| `src/core/config/generate.odin` | `generate_source` renders the staged package; `write_staged` writes it atomically (temp + rename). |
| `src/core/config/discovery.odin` | `discover`: `--config` → `HAMMER_CONFIG` → per-user path (XDG/APPDATA); missing explicit files are build errors, "not found" means defaults. |
| `src/config/generated/generated.odin` | The staged package (gitignored; the file is regenerated on every build). Carries a `#assert` on `SCHEMA_VERSION` so a stale file cannot silently compile against a changed schema. |
| `configs/example.yaml` | Fully commented example config (schema + trust boundary + reserved keys). |

Build tool (`make.odin`):

- Every product build (debug/release/run/windows) first resolves the
  config, prints a one-line summary, and regenerates the staged
  package. `--config=<path>` / `HAMMER_CONFIG` select the trusted file;
  `--no-config` forces built-in defaults; `--init-config <path>` writes
  the commented example (never overwrites).
- Any malformed config **fails the build** with a file:line message:
  unknown keys, reserved-but-unimplemented keys (`keybindings`,
  `terminal`, … → "not yet supported"), partial themes, bad colors,
  out-of-range sizes, tabs, structural YAML.

Application (`src/main.odin`):

- Binds `generated.resolved` as the process config; the window clear
  color is the configured `theme.body_bg` (visibly configurable), and
  the startup log prints the full resolved summary.

Tests: `tests/unit/config` (13 tests: defaults, merge, sources, all
reject paths, list/quoting forms, hex parsing, generated-source
content, describe).

## Design contracts

### Trust boundary (SPECS.md §14.4, AGENTS.md §18)

Only explicitly trusted inputs are ever staged: the `--config` path,
`HAMMER_CONFIG`, or the per-user config file. Project-local configs are
never auto-discovered. The staged input is **data** (YAML), parsed and
validated at build time — nothing is compiled or executed from user
configuration at runtime. The planned M11 `ConfigBuild` flow (async
build, output window, restart/handoff) extends this staging, it does
not replace it.

### Schema discipline

- Zero means "fill from defaults" for every scalar (there is no valid
  zero value for a font size or a color, so the encoding is
  unambiguous). A theme is all-ten-colors or absent: partial themes are
  rejected, so the generated package always carries a complete theme.
- Unknown keys are hard errors — never silently ignored. Known future
  schema keys (SPECS.md §14.2) are rejected as `.Unsupported` with a
  specific message.
- `SCHEMA_VERSION` guards the generated file: a shape change bumps it
  and a stale staged file fails to compile, telling the user to rebuild
  via make.odin.

### Ownership

- `resolve_from_yaml`/`resolve_from_path`/`builtin` return a `Resolved`
  that **owns** deep-copied family strings (`resolved_destroy`).
- The generated package's `resolved` is a static global — never
  destroy it.
- Binding lives in `src/main.odin`, not in `core/config`: the generated
  package imports `core/config` for its types, so importing it back
  would be a cycle. `core/config` stays backend-free (M01 acceptance).

### Allocation discipline (AGENTS.md §10.5)

No code in this task touches the scratch arena. The product has no
frame arena yet, so a `free_all` boundary does not exist anywhere — a
scratch allocation made now would live for the whole process:

- `describe` returns a caller-owned string (default
  `context.allocator`); `src/main.odin` and `make.odin` free it, so it
  is covered by the product's tracking allocator and the build tool's
  exit-time cleanup. The default is deliberately not the temp arena.
- `errs.describe` in `make.odin` goes through `config_fail`, which
  passes `context.allocator` explicitly and frees before exit.
- The YAML parser threads its allocator through
  `parse_scalar`/`parse_value`/`document_destroy` — including the
  single-quoted `''`-unescape allocation (marked `owned` and freed with
  the same allocator).
- Config discovery reads environment variables into stack buffers
  (`os.get_env(buf, key)`), so it allocates exactly one string: the
  owned result path.

When per-frame scratch needs arrive (M01.06 rendering), they get an
explicit arena with `free_all` at a documented frame boundary; nothing
in this task pre-uses that arena. The remaining
`context.temp_allocator` uses in `src/main.odin` are pre-existing
M01.01 startup code (one-shot env reads, bounded by count, each called
exactly once before the main loop); switching them to the same
stack-buffer pattern is a recorded follow-up.

### Staging atomicity

`write_staged` writes a `.tmp` file and renames: an interrupted build
never leaves a torn generated file. The staging step is unconditional
and deterministic, so the generated file can never drift from the
config source.

## Validation run (all commands executed this session)

```text
odin run make.odin -file                      -> stage (builtin defaults) + debug build, exit 0
./build/make test                             -> 30/30 unit tests pass, leak-checked
    (errs 6, logging 5, lifecycle 5, platform 1, config 13)
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG=$S ./build/hammer
    -> exit 0; log line: config: source=builtin defaults, ... body_bg=#161616;
       no leaked allocations at exit (tracking allocator)
--config=<sandbox config> (21pt, #112233, custom families, ligatures)
    -> staged file + runtime log carry all values; exit 0
release build + smoke                            -> exit 0
run mode (odin run make.odin -file -- run)       -> exit 0
--init-config <path>                             -> writes example; refuses existing files
--no-config                                      -> forces builtin defaults
Error paths (each fails the build with file:line): unknown key,
    reserved key (unsupported), partial theme, bad color, out-of-range
    font size/line height, tab indentation, non-numeric field, missing
    explicit file, HAMMER_CONFIG pointing at a missing file.
Windows: ./build/make windows --no-config        -> hammer.exe builds (-no-crt)
    xvfb-run + Wine 11 smoke                     -> exit 0; identical config line
    (os=Windows console logging; see m01-01 doc for the prefix setup)
```

## Traps found (recorded for later tasks)

1. **Odin fmt treats `{`/`}` as format syntax** (Python-like `{:v}`):
   literal braces in `fmt.aprintf` templates must be doubled (`{{`,
   `}}`), and `%.9g`-style precision is not supported — use `%v`
   (shortest round-trip, exact enough for 0..255 colors).
2. **Odin defers are block-scoped**: a `defer` inside an `if` block
   runs at the end of that block, not the proc. Two real bugs this
   session: make.odin's staging destroyed the resolved config before
   use, and the generator freed the family-literal before `aprintf`
   copied it.
3. **Relative import paths are resolved against the importing file's
   directory** (verified in the pinned compiler source:
   `dir_from_path(filepath)`), including across collection roots.
   `src/core/config` reaches `src/config/generated` as
   `../../config/generated`; `make.odin` (repo root) reaches
   `src/core/config` as `src/core/config` — with no extra
   `-collection` flag needed for `odin run make.odin -file`.
4. **A `[]string` constant is not a constant**: the default family list
   must be a package-level `@(rodata)` variable so returning it from a
   proc does not flag Odin's escape analysis.
5. **`strconv.parse_f64` returns `(f64, bool)`** in the pinned version
   (the consumed-count is an optional out-param, not a return value).
6. **Eager error creation leaks**: `parse_hex_color` originally
   allocated its error on every call; errors must be created only on
   the failure path and wrapped errors must destroy their inner error.
   The tracking allocator caught all of these.
7. **No scratch arena without a `free_all` boundary**: the product has
   no frame arena, so any `context.temp_allocator` use is permanent
   process-lifetime growth. The config code therefore avoids the temp
   arena entirely (caller-owned `describe`, stack-buffered env reads,
   allocator-threaded YAML parsing). Per-frame scratch must wait for an
   explicit arena with a documented reset point (AGENTS.md §10.5).

## Honest status

| Platform  | Status |
| --------- | ------ |
| Linux/X11 | **tested headless** (unit tests, debug/release smokes, full config pipeline incl. every error path, leak-free exit). The "visibly change" acceptance is validated through the compiled clear color + runtime log; a real-desktop visual check remains the recorded M01 follow-up. |
| Windows   | **cross-build + Wine-validated** (config pipeline compiles under `-no-crt`, identical resolved config at runtime). Real Windows hardware untested (D-02). |

## Follow-ups (owners)

- M01.03 (logical/physical coordinates) and M01.06 (rectangles) consume
  `resolved.Theme`; the font service milestone (M05) consumes
  `Font_Families`/`Font_Size_Points`/`Line_Height`/`Ligatures`.
- M11 extends the schema with the reserved keys, the EditorConfig
  interplay, and the async `ConfigBuild` flow (SPECS.md §14.3).
- Real-desktop visual validation of the config-driven clear color (M01
  general follow-up, pre-existing).
