// Package config: the editor's compiled configuration.
//
// Design (SPECS.md §14): the product compiles the configuration into the
// binary. The trusted user config is a plain YAML data file; the build
// tool (make.odin) parses and validates it at build time and stages the
// result into the generated package `src/config/generated` (see
// `generate.odin`). The generated package is compiled into the binary,
// so config edits take effect after a rebuild — the M01 acceptance rule.
//
// Trust boundary (SPECS.md §14.4, AGENTS.md §18): only an explicitly
// trusted config file is ever staged. The build tool never auto-loads a
// project-local config, and the product never compiles or executes
// configuration at runtime. The staged input is data (YAML), not code.
//
// This package is backend-free: it imports nothing but `core:` and the
// sibling `errs` package, and it must keep building without the Sokol
// collection (M01 acceptance).
package config

import errs "../errs"

// --- Schema (SPECS.md §14.2) ------------------------------------------

// Theme carries the colors used for rendering. Every color is RGBA in
// linear 0..1 floats, the form sokol_gfx consumes directly; the YAML
// input expresses them as "#RRGGBB" strings (alpha = 1).
Theme :: struct {
	Body_Bg:      [4]f32,
	Body_Fg:      [4]f32,
	Tag_Bg:       [4]f32,
	Tag_Fg:       [4]f32,
	Selection_Bg: [4]f32,
	Selection_Fg: [4]f32,
	Caret:        [4]f32,
	Git_Added:    [4]f32,
	Git_Modified: [4]f32,
	Git_Deleted:  [4]f32,
}

// Config is the user-facing schema. Fields left zero are filled from
// the defaults by `resolve_from_yaml`/`resolved`; there is deliberately
// no way to spell "empty" for a color or a negative font size, so
// zero-means-default is unambiguous.
Config :: struct {
	Font_Families:    []string,
	Font_Size_Points: f32,
	Line_Height:      f32,
	Ligatures:        bool,
	Theme:            Theme,
}

// Resolved is the fully-resolved configuration after validation and
// default filling. This is what `load` returns and what the generated
// package carries.
Resolved :: struct {
	Font_Families:    []string,
	Font_Size_Points: f32,
	Line_Height:      f32,
	Ligatures:        bool,
	Theme:            Theme,
	Source:           Source, // where the config came from
}

// Source identifies where a configuration came from.
Source :: enum {
	Builtin, // repository defaults; no user config was found
	File, // staged from a trusted user config file
}

// source_name renders a Source for diagnostics.
source_name :: proc(source: Source) -> string {
	switch source {
	case .Builtin:
		return "builtin defaults"
	case .File:
		return "config file"
	}
	return "unknown"
}

// Bounds for the user-editable scalar fields. Values outside these are
// rejected with `.Invalid_Input` — silently clamping a typo like a font
// size of 200 would hide the mistake (AGENTS.md §11.1).
MIN_FONT_SIZE :: 4.0
MAX_FONT_SIZE :: 72.0
MIN_LINE_HEIGHT :: 0.5
MAX_LINE_HEIGHT :: 3.0
MAX_FONT_FAMILIES :: 4
MAX_FONT_FAMILY_LEN :: 64

// SCHEMA_VERSION is bumped whenever the generated-package shape
// changes. The generated file carries the version it was staged with
// and fails to compile against a mismatching schema.
SCHEMA_VERSION :: 1

// parse_hex_color converts "#RRGGBB" into a [4]f32 RGBA color (alpha
// forced to 1). Returns `.Invalid_Input` on a malformed string.
parse_hex_color :: proc(text: string) -> ([4]f32, errs.Error) {
	if len(text) != 7 || text[0] != '#' {
		return [4]f32{}, errs.newf(.Invalid_Input, "color %q: expected #RRGGBB", text)
	}
	hex_value :: proc(c: u8) -> (int, bool) {
		switch c {
		case '0' ..= '9':
			return int(c - '0'), true
		case 'a' ..= 'f':
			return int(c - 'a' + 10), true
		case 'A' ..= 'F':
			return int(c - 'A' + 10), true
		}
		return 0, false
	}
	channel :: proc(text: string, at: int) -> (f32, bool) {
		hi, hi_ok := hex_value(text[at])
		lo, lo_ok := hex_value(text[at + 1])
		if !hi_ok || !lo_ok {
			return 0, false
		}
		return f32(hi*16 + lo) / 255.0, true
	}
	r, r_ok := channel(text, 1)
	g, g_ok := channel(text, 3)
	b, b_ok := channel(text, 5)
	if !r_ok || !g_ok || !b_ok {
		return [4]f32{}, errs.newf(.Invalid_Input, "color %q: expected #RRGGBB", text)
	}
	return [4]f32{r, g, b, 1.0}, errs.Error{}
}

// validate checks the user-facing constraints of `c`. Zero/empty values
// are fine here — resolution fills them from defaults first.
validate :: proc(c: Config) -> errs.Error {
	if len(c.Font_Families) > MAX_FONT_FAMILIES {
		return errs.newf(
			.Invalid_Input,
			"config: at most %d font families allowed, got %d",
			MAX_FONT_FAMILIES,
			len(c.Font_Families),
		)
	}
	for family, i in c.Font_Families {
		if len(family) == 0 {
			return errs.newf(.Invalid_Input, "config: font_families[%d] is empty", i)
		}
		if len(family) > MAX_FONT_FAMILY_LEN {
			return errs.newf(
				.Invalid_Input,
				"config: font_families[%d] longer than %d bytes",
				i,
				MAX_FONT_FAMILY_LEN,
			)
		}
		// The generator stages family names as ".." Odin string
		// literals; reject characters that cannot be represented that
		// way (they are also meaningless in a font family name).
		for c in family {
			if c == '"' || c == '\\' || c == '\n' || c == '\r' || c == '\t' {
				return errs.newf(
					.Invalid_Input,
					"config: font_families[%d] contains a character that cannot be staged (%q)",
					i,
					c,
				)
			}
		}
	}
	if c.Font_Size_Points != 0 {
		if c.Font_Size_Points < MIN_FONT_SIZE || c.Font_Size_Points > MAX_FONT_SIZE {
			return errs.newf(
				.Invalid_Input,
				"config: font_size_points %v outside [%v, %v]",
				c.Font_Size_Points,
				MIN_FONT_SIZE,
				MAX_FONT_SIZE,
			)
		}
	}
	if c.Line_Height != 0 {
		if c.Line_Height < MIN_LINE_HEIGHT || c.Line_Height > MAX_LINE_HEIGHT {
			return errs.newf(
				.Invalid_Input,
				"config: line_height %v outside [%v, %v]",
				c.Line_Height,
				MIN_LINE_HEIGHT,
				MAX_LINE_HEIGHT,
			)
		}
	}
	return errs.Error{}
}
