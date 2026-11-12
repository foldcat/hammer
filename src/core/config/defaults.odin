// Built-in configuration defaults.
//
// The theme is the modified oxocarbon colorscheme (SPECS.md §14.4),
// taken from the repository's `colorscheme.yaml`; a unit test cross-
// checks the parsed YAML palette against these constants so the two
// cannot drift silently. All values here are compile-time constants:
// `defaults()` returns borrowed, static data that is never freed
// (AGENTS.md §10.3).
package config

// Default font stack. Renderer milestones (M05) consume this through
// the font service; each family is tried in order until one is found.
// A package-level variable (not a const): a `[]string` is a runtime
// value, and its backing store is static so `defaults()` can return
// slices into it safely. Read-only by convention.
@(rodata)
DEFAULT_FONT_FAMILIES := []string {
	"JetBrains Mono",
	"DejaVu Sans Mono",
	"Liberation Mono",
	"monospace",
}

DEFAULT_FONT_SIZE_POINTS :: 12.0
DEFAULT_LINE_HEIGHT :: 1.4

// Oxocarbon palette from colorscheme.yaml (base00..base0F), as the
// "#RRGGBB" strings the palette file uses.
OXOCARBON :: [16]string {
	"#161616", // base00
	"#262626", // base01
	"#393939", // base02
	"#525252", // base03
	"#dde1e6", // base04
	"#f2f4f8", // base05
	"#ffffff", // base06
	"#7088d4", // base07
	"#89b4fa", // base08
	"#78a9ff", // base09
	"#ee5396", // base0A
	"#33b1ff", // base0B
	"#ff7eb6", // base0C
	"#42be65", // base0D
	"#be95ff", // base0E
	"#b4befe", // base0F
}

// default_theme returns the oxocarbon-derived theme (channels are the
// 0..255 palette bytes over 255; alpha is 1). Every color is a static
// array; copying the struct copies the borrow.
default_theme :: proc() -> Theme {
	return Theme{
		Body_Bg = {22.0 / 255.0, 22.0 / 255.0, 22.0 / 255.0, 1.0}, // base00
		Body_Fg = {242.0 / 255.0, 244.0 / 255.0, 248.0 / 255.0, 1.0}, // base05
		Tag_Bg = {38.0 / 255.0, 38.0 / 255.0, 38.0 / 255.0, 1.0}, // base01
		Tag_Fg = {208.0 / 255.0, 225.0 / 255.0, 230.0 / 255.0, 1.0}, // base04
		Selection_Bg = {51.0 / 255.0, 177.0 / 255.0, 255.0 / 255.0, 1.0}, // base0B
		Selection_Fg = {22.0 / 255.0, 22.0 / 255.0, 22.0 / 255.0, 1.0}, // base00
		Caret = {242.0 / 255.0, 244.0 / 255.0, 248.0 / 255.0, 1.0}, // base05
		Git_Added = {66.0 / 255.0, 190.0 / 255.0, 101.0 / 255.0, 1.0}, // base0D
		Git_Modified = {238.0 / 255.0, 83.0 / 255.0, 150.0 / 255.0, 1.0}, // base0A
		Git_Deleted = {255.0 / 255.0, 126.0 / 255.0, 182.0 / 255.0, 1.0}, // base0C
	}
}

// defaults returns the built-in configuration. The returned value and
// every slice inside it are static and must not be freed.
defaults :: proc() -> Config {
	return Config{
		Font_Families = DEFAULT_FONT_FAMILIES,
		Font_Size_Points = DEFAULT_FONT_SIZE_POINTS,
		Line_Height = DEFAULT_LINE_HEIGHT,
		Ligatures = false,
		Theme = default_theme(),
	}
}
