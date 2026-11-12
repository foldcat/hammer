// Package config: the editor's compiled configuration.
//
// This package owns the schema (SPECS.md §14.2), the built-in defaults
// (the modified oxocarbon theme, `colorscheme.yaml`), validation, the
// YAML-subset parser, and the staging machinery the build tool uses to
// generate the compiled-in configuration package
// (`src/config/generated`): SPECS.md §14.1. Config edits take effect
// after a rebuild — the M01 acceptance rule.
//
// The compiled configuration value itself lives in the generated
// package; the application layer binds it (`src/main.odin` reads
// `generated.resolved`). Binding lives outside this package on
// purpose: the generated package imports this package for its types,
// so this package importing it back would be a cycle.
//
// Trust boundary (SPECS.md §14.4, AGENTS.md §18): only explicitly
// trusted config files are ever staged (`discover`: --config /
// HAMMER_CONFIG / the per-user path). Nothing here compiles or executes
// anything at runtime; the staged input is validated data.
//
// Ownership:
//   - `resolve_from_yaml` returns a Config whose strings are owned
//     copies (allocated with the passed allocator); free them with
//     `config_destroy`.
//   - `generate_source` returns an owned string (passed allocator).
//
// This package is backend-free: it imports nothing but `core:` and the
// sibling `errs` package (M01 acceptance).
package config
