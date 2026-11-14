## M01.02 done (2026-11-12 session)

Generated trusted configuration package (`docs/m01-02-config.md`):

- `src/core/config` (backend-free): schema (SPECS.md §14.2 fonts/theme
  structs, exported fields, bounds), oxocarbon defaults from
  `colorscheme.yaml`, a strict YAML-subset parser (no new dependency),
  resolve/validate/default-fill with owned deep-copied results,
  `generate_source` + atomic `write_staged`, config discovery
  (`--config`/`HAMMER_CONFIG`/per-user path, never project-local).
- Staged package `src/config/generated` (gitignored, regenerated on
  every build, `SCHEMA_VERSION`-asserted); `configs/example.yaml`;
  `--init-config`/`--no-config` make targets; every malformed config
  fails the build with file:line errors (unknown/reserved keys,
  partial themes, bad colors, out-of-range values, tabs).
- `src/main.odin` binds `generated.resolved`; the clear color is the
  configured `theme.body_bg` and the startup log prints the resolved
  summary — config edits visibly change colors after rebuild (M01
  acceptance).
- Tests moved to `tests/unit/config` (13); 30/30 unit tests leak-free.
  Validated: debug/release/run builds, full custom-config pipeline,
  every error path, Windows cross-build + Wine 11 smoke (config under
  `-no-crt`). Traps recorded in `docs/m01-02-config.md` §Traps.

