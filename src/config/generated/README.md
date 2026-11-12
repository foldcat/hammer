This directory holds the generated, staged configuration package
(`generated.odin`), written by make.odin on every build from the
trusted user config (or the built-in defaults when no config exists).
The file is gitignored generated output — never edit it by hand; edit
the config source instead. See `src/core/config` and
`docs/m01-02-config.md`.
