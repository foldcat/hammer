// Resolution: turn raw input (the YAML config text, or a Config value
// built programmatically) into a validated, fully-defaulted Resolved.
//
// Ownership (AGENTS.md §10.1):
//   - `resolve_from_yaml`/`resolve_from_path` return a Resolved that
//     owns its strings (the font family names, allocated with the
//     passed allocator). Release with `resolved_destroy`.
//   - `resolved` clones the Config's font families into the result, so
//     the caller may destroy the Config immediately afterwards.
//   - The generated package's `resolved` value is a static global; it
//     must never be passed to `resolved_destroy`.
package config

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import errs "../errs"

// config_destroy releases the strings owned by a Config produced by
// `build_config`/`resolve_from_yaml`. `allocator` must match the one
// that built the Config. Safe on a zero Config.
config_destroy :: proc(c: ^Config, allocator := context.allocator) {
	for family in c.Font_Families {
		delete(family, allocator)
	}
	delete(c.Font_Families, allocator)
	c^ = Config{}
}

// resolved_destroy releases the strings owned by a Resolved produced by
// `resolve_from_yaml`/`resolve_from_path`/`resolved`/`builtin`.
// `allocator` must match the one that produced the Resolved. Never call
// it on the generated package's static value. Safe on a zero Resolved.
resolved_destroy :: proc(r: ^Resolved, allocator := context.allocator) {
	for family in r.Font_Families {
		delete(family, allocator)
	}
	delete(r.Font_Families, allocator)
	r^ = Resolved{}
}

// resolve_from_yaml parses the YAML text, applies the built-in
// defaults, validates everything, and returns the resolved
// configuration. The result owns its strings (allocated with
// `allocator`); release with `resolved_destroy`.
resolve_from_yaml :: proc(
	text: string,
	source := Source.Builtin,
	allocator := context.allocator,
) -> (
	Resolved,
	errs.Error,
) {
	doc, parse_err := parse_document(text, allocator)
	if !errs.ok(parse_err) {
		return Resolved{}, parse_err
	}
	defer document_destroy(&doc)

	cfg, build_err := build_config(&doc.root, allocator)
	if !errs.ok(build_err) {
		config_destroy(&cfg, allocator)
		return Resolved{}, build_err
	}
	defer config_destroy(&cfg, allocator)
	return resolved(cfg, source, allocator)
}

// builtin returns the resolved built-in configuration (owned strings;
// release with `resolved_destroy`).
builtin :: proc(allocator := context.allocator) -> (Resolved, errs.Error) {
	return resolved(defaults(), .Builtin, allocator)
}

// resolved fills a Config with defaults, validates it, and clones the
// font families into an owned Resolved (allocated with `allocator`;
// release with `resolved_destroy`). `c` may be zero-valued (pure
// defaults).
resolved :: proc(c: Config, source: Source, allocator := context.allocator) -> (Resolved, errs.Error) {
	if val_err := validate(c); !errs.ok(val_err) {
		return Resolved{}, val_err
	}
	d := defaults()

	r := Resolved{
		Font_Size_Points = c.Font_Size_Points,
		Line_Height = c.Line_Height,
		Ligatures = c.Ligatures,
		Theme = c.Theme,
		Source = source,
	}
	if r.Font_Size_Points == 0 {
		r.Font_Size_Points = d.Font_Size_Points
	}
	if r.Line_Height == 0 {
		r.Line_Height = d.Line_Height
	}

	// Font families: user list wins, otherwise the defaults; either way
	// the Resolved gets its own deep copy (the Config may be destroyed
	// immediately afterwards).
	clone_families :: proc(src: []string, allocator: runtime.Allocator) -> []string {
		out := make([]string, len(src), allocator)
		for family, i in src {
			out[i] = strings.clone(family, allocator)
		}
		return out
	}
	if len(c.Font_Families) > 0 {
		r.Font_Families = clone_families(c.Font_Families, allocator)
	} else {
		r.Font_Families = clone_families(d.Font_Families, allocator)
	}

	// Theme: any zero color means "defaults were not fully provided";
	// merge per color so partial themes are impossible (the generated
	// package always carries the complete theme).
	merge_color :: proc(dst: ^[4]f32, src: [4]f32) {
		if dst^ == ([4]f32{}) {
			dst^ = src
		}
	}
	merge_color(&r.Theme.Body_Bg, d.Theme.Body_Bg)
	merge_color(&r.Theme.Body_Fg, d.Theme.Body_Fg)
	merge_color(&r.Theme.Tag_Bg, d.Theme.Tag_Bg)
	merge_color(&r.Theme.Tag_Fg, d.Theme.Tag_Fg)
	merge_color(&r.Theme.Selection_Bg, d.Theme.Selection_Bg)
	merge_color(&r.Theme.Selection_Fg, d.Theme.Selection_Fg)
	merge_color(&r.Theme.Caret, d.Theme.Caret)
	merge_color(&r.Theme.Git_Added, d.Theme.Git_Added)
	merge_color(&r.Theme.Git_Modified, d.Theme.Git_Modified)
	merge_color(&r.Theme.Git_Deleted, d.Theme.Git_Deleted)
	return r, errs.Error{}
}

// describe renders a one-line human-readable summary of the resolved
// configuration. The result is owned by the caller (allocated with
// `allocator`); free it with `delete`. There is deliberately no
// scratch-arena default: the product has no frame arena yet, and
// un-freed scratch allocations would accumulate for the process
// lifetime (AGENTS.md §10.5).
describe :: proc(r: Resolved, allocator := context.allocator) -> string {
	families, join_err := strings.join(r.Font_Families, ", ", allocator)
	defer if join_err == nil {
		delete(families, allocator)
	}
	if join_err != nil {
		families = "?"
	}
	return fmt.aprintf(
		"config: source=%s, font_size=%.1fpt, line_height=%.2f, ligatures=%v, families=[%s], body_bg=#%02x%02x%02x",
		source_name(r.Source),
		r.Font_Size_Points,
		r.Line_Height,
		r.Ligatures,
		families,
		u8(r.Theme.Body_Bg[0] * 255.0 + 0.5),
		u8(r.Theme.Body_Bg[1] * 255.0 + 0.5),
		u8(r.Theme.Body_Bg[2] * 255.0 + 0.5),
		allocator = allocator,
	)
}

// --- YAML document -> Config ------------------------------------------

// build_config reads the parsed root mapping into a Config. Unknown
// keys are errors (never silently dropped); keys that belong to a later
// schema version get a specific "not yet supported" error. The Config
// owns its strings (allocated with `allocator`); release with
// `config_destroy`.
build_config :: proc(root: ^map_node, allocator := context.allocator) -> (Config, errs.Error) {
	cfg: Config
	seen := make(map[string]bool, 8, allocator)
	defer delete(seen)

	for key, node in root.entries {
		seen[key] = true
		switch key {
		case "font_families":
			list, is_list := node.([]value)
			if !is_list {
				return cfg, errs.newf(
					.Invalid_Input,
					"config: line %d: font_families must be a list",
					root.lines[key],
				)
			}
			families := make([]string, len(list), allocator)
			for item, i in list {
				if item.kind != .String {
					for done in families[:i] {
						delete(done)
					}
					delete(families)
					return cfg, errs.newf(
						.Invalid_Input,
						"config: line %d: font_families[%d] must be a quoted string",
						root.lines[key],
						i,
					)
				}
				families[i] = strings.clone(item.text, allocator)
			}
			cfg.Font_Families = families
		case "font_size_points":
			scalar, is_scalar := node.(value)
			if !is_scalar || scalar.kind == .String {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: font_size_points must be a number", root.lines[key])
			}
			value_parsed, value_ok := strconv.parse_f64(scalar.text)
			if !value_ok {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: invalid font_size_points", root.lines[key])
			}
			cfg.Font_Size_Points = f32(value_parsed)
		case "line_height":
			scalar, is_scalar := node.(value)
			if !is_scalar || scalar.kind == .String {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: line_height must be a number", root.lines[key])
			}
			value_parsed, value_ok := strconv.parse_f64(scalar.text)
			if !value_ok {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: invalid line_height", root.lines[key])
			}
			cfg.Line_Height = f32(value_parsed)
		case "ligatures":
			scalar, is_scalar := node.(value)
			if !is_scalar || scalar.kind != .Bool {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: ligatures must be true or false", root.lines[key])
			}
			cfg.Ligatures = scalar.text == "true" || scalar.text == "True" || scalar.text == "TRUE"
		case "theme":
			child, is_map := node.(^map_node)
			if !is_map {
				return cfg, errs.newf(.Invalid_Input, "config: line %d: theme must be a mapping", root.lines[key])
			}
			theme_err := build_theme(&cfg.Theme, child, allocator)
			if !errs.ok(theme_err) {
				return cfg, theme_err
			}
		case:
			// Explicitly-not-yet-supported schema fields (SPECS.md §14.2
			// "actual configuration should also support"): rejecting them
			// is honest — silently ignoring a keybindings block would be
			// worse than failing the build.
			if is_reserved_key(key) {
				return cfg, errs.newf(
					.Unsupported,
					"config: line %d: key %q is part of the planned schema but not yet supported",
					root.lines[key],
					key,
				)
			}
			return cfg, errs.newf(.Invalid_Input, "config: line %d: unknown key %q", root.lines[key], key)
		}
	}
	return cfg, errs.Error{}
}

// build_theme reads the `theme:` mapping into a Theme. A partial theme
// is rejected: mixing is a config mistake, not a merge request.
build_theme :: proc(theme: ^Theme, node: ^map_node, allocator := context.allocator) -> errs.Error {
	theme_fields := 0
	for key, entry in node.entries {
		scalar, is_scalar := entry.(value)
		if !is_scalar || scalar.kind != .String {
			return errs.newf(
				.Invalid_Input,
				"config: line %d: theme.%s must be a #RRGGBB color string",
				node.lines[key],
				key,
			)
		}
		color, color_err := parse_hex_color(scalar.text)
		if !errs.ok(color_err) {
			desc := errs.describe(color_err, allocator)
			wrapped := errs.newf(.Invalid_Input, "config: line %d: %s", node.lines[key], desc)
			delete(desc, allocator)
			errs.destroy(&color_err)
			return wrapped
		}
		switch key {
		case "body_bg":
			theme.Body_Bg = color
		case "body_fg":
			theme.Body_Fg = color
		case "tag_bg":
			theme.Tag_Bg = color
		case "tag_fg":
			theme.Tag_Fg = color
		case "selection_bg":
			theme.Selection_Bg = color
		case "selection_fg":
			theme.Selection_Fg = color
		case "caret":
			theme.Caret = color
		case "git_added":
			theme.Git_Added = color
		case "git_modified":
			theme.Git_Modified = color
		case "git_deleted":
			theme.Git_Deleted = color
		case:
			if is_reserved_key(key) {
				return errs.newf(
					.Unsupported,
					"config: line %d: theme key %q is part of the planned schema but not yet supported",
					node.lines[key],
					key,
				)
			}
			return errs.newf(.Invalid_Input, "config: line %d: unknown theme key %q", node.lines[key], key)
		}
		theme_fields += 1
	}
	// A partial theme is rejected outright (all 10 colors or none).
	if theme_fields != 0 && theme_fields != 10 {
		return errs.newf(
			.Invalid_Input,
			"config: theme must set all %d colors or be omitted (got %d); no partial themes",
			10,
			theme_fields,
		)
	}
	return errs.Error{}
}

// is_reserved_key reports whether a key is a known future schema field
// (SPECS.md §14.2) that this milestone deliberately rejects instead of
// ignoring.
is_reserved_key :: proc(key: string) -> bool {
	switch key {
	case "tag_font_families", "console_font_families", "keybindings", "touchpad_bindings", "syntax_styles", "large_file_threshold", "history_budget", "recovery_interval", "shell", "clipboard_policy", "finder_exclusions", "terminal":
		return true
	}
	return false
}

// resolve_from_path reads and resolves a config file. A missing file is
// a caller error, not a default: the caller decides when defaults apply
// (see `discover`). The result owns its strings (allocated with
// `allocator`); release with `resolved_destroy`.
resolve_from_path :: proc(path: string, allocator := context.allocator) -> (Resolved, errs.Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return Resolved{}, errs.newf(.IO, "config: cannot read %s: %v", path, read_err)
	}
	defer delete(data, allocator)
	return resolve_from_yaml(string(data), .File, allocator)
}
