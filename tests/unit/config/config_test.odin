// Tests for the compiled configuration package (M01.02):
// `hammer:core/config` — schema, defaults, YAML-subset parsing,
// validation, resolution, and source generation.
//
// The generated/staged package itself is exercised by the build: every
// `make` run regenerates `src/config/generated/generated.odin` from the
// trusted config and the product build compiles it (see the M01.02
// session doc for the end-to-end validation).
package config_test

import "core:math"
import "core:strings"
import "core:testing"

import config "hammer:core/config"
import errs "hammer:core/errs"

// A complete, valid theme block for tests that need one.
FULL_THEME_YAML :: `theme:
  body_bg:      "#112233"
  body_fg:      "#fefefe"
  tag_bg:       "#332211"
  tag_fg:       "#abcdef"
  selection_bg: "#ff0000"
  selection_fg: "#00ff00"
  caret:        "#0000ff"
  git_added:    "#123456"
  git_modified: "#654321"
  git_deleted:  "#987654"
`

expect_near :: proc(t: ^testing.T, got, want: f32, what: string, epsilon := f32(0.001)) {
	testing.expectf(
		t,
		math.abs(got - want) <= epsilon,
		"%s: got %v, want %v (+/- %v)",
		what,
		got,
		want,
		epsilon,
	)
}

// expect_fail asserts that resolving fails with the given errs.Kind
// name inside the described error ("invalid input", "unsupported").
expect_fail :: proc(t: ^testing.T, yaml: string, kind_name: string) {
	_, err := config.resolve_from_yaml(yaml)
	defer errs.destroy(&err)
	testing.expectf(t, !errs.ok(err), "expected %s, got no error for: %q", kind_name, yaml)
	if !errs.ok(err) {
		desc := errs.describe(err, context.allocator)
		defer delete(desc, context.allocator)
		testing.expectf(
			t,
			strings.contains(desc, kind_name),
			"expected %s, got: %s",
			kind_name,
			desc,
		)
	}
}

@(test)
test_builtin_defaults :: proc(t: ^testing.T) {
	r, err := config.builtin()
	defer config.resolved_destroy(&r)

	testing.expect(t, errs.ok(err))
	testing.expect(t, r.Source == .Builtin)
	testing.expect(t, len(r.Font_Families) == 4)
	testing.expect(t, r.Font_Families[0] == "JetBrains Mono")
	expect_near(t, r.Font_Size_Points, 12.0, "font size")
	expect_near(t, r.Line_Height, 1.4, "line height")
	testing.expect(t, !r.Ligatures)
	// Oxocarbon body_bg #161616.
	expect_near(t, r.Theme.Body_Bg[0], 22.0 / 255.0, "body_bg.r")
	expect_near(t, r.Theme.Body_Bg[1], 22.0 / 255.0, "body_bg.g")
	expect_near(t, r.Theme.Body_Bg[2], 22.0 / 255.0, "body_bg.b")
	expect_near(t, r.Theme.Body_Bg[3], 1.0, "body_bg.a")
}

@(test)
test_user_overrides_merge_with_defaults :: proc(t: ^testing.T) {
	yaml := `font_families:
  - "Test Mono"
  - "monospace"
font_size_points: 21
line_height: 1.8
ligatures: true
` + FULL_THEME_YAML

	r, err := config.resolve_from_yaml(yaml)
	defer config.resolved_destroy(&r)

	testing.expect(t, errs.ok(err))
	testing.expect(t, len(r.Font_Families) == 2)
	testing.expect(t, r.Font_Families[0] == "Test Mono")
	expect_near(t, r.Font_Size_Points, 21.0, "font size")
	expect_near(t, r.Line_Height, 1.8, "line height")
	testing.expect(t, r.Ligatures)
	// #112233 -> 0x11, 0x22, 0x33.
	expect_near(t, r.Theme.Body_Bg[0], 17.0 / 255.0, "body_bg.r")
	expect_near(t, r.Theme.Body_Bg[1], 34.0 / 255.0, "body_bg.g")
	expect_near(t, r.Theme.Body_Bg[2], 51.0 / 255.0, "body_bg.b")
}

@(test)
test_file_source_and_missing_theme_uses_defaults :: proc(t: ^testing.T) {
	r, err := config.resolve_from_yaml("font_size_points: 18\n", .File)
	defer config.resolved_destroy(&r)

	testing.expect(t, errs.ok(err))
	testing.expect(t, r.Source == .File)
	expect_near(t, r.Font_Size_Points, 18.0, "font size")
	// No theme in the input: defaults apply completely.
	expect_near(t, r.Theme.Body_Bg[0], 22.0 / 255.0, "body_bg.r")
	expect_near(t, r.Line_Height, 1.4, "line height")
}

@(test)
test_rejects_unknown_key :: proc(t: ^testing.T) {
	expect_fail(t, "frotz: 1\n", "invalid input")
}

@(test)
test_rejects_reserved_future_key :: proc(t: ^testing.T) {
	expect_fail(t, "keybindings: []\n", "unsupported")
}

@(test)
test_rejects_partial_theme :: proc(t: ^testing.T) {
	expect_fail(t, "theme:\n  body_bg: \"#112233\"\n", "invalid input")
}

@(test)
test_rejects_bad_color :: proc(t: ^testing.T) {
	bad := `theme:
  body_bg: "red"
  body_fg: "#fefefe"
  tag_bg: "#332211"
  tag_fg: "#abcdef"
  selection_bg: "#ff0000"
  selection_fg: "#00ff00"
  caret: "#0000ff"
  git_added: "#123456"
  git_modified: "#654321"
  git_deleted: "#987654"
`
	expect_fail(t, bad, "invalid input")
}

@(test)
test_rejects_out_of_range_values :: proc(t: ^testing.T) {
	expect_fail(t, "font_size_points: 999\n", "invalid input")
	expect_fail(t, "line_height: 0.1\n", "invalid input")
	expect_fail(t, "font_size_points: -3\n", "invalid input")
}

@(test)
test_rejects_tab_indentation :: proc(t: ^testing.T) {
	expect_fail(t, "theme:\n\tbody_bg: \"#112233\"\n", "invalid input")
}

@(test)
test_yaml_list_forms_and_quoting :: proc(t: ^testing.T) {
	// Block list, quoted values, comments, blank lines, single-quoted
	// scalar with an escaped quote.
	yaml := `# a comment
font_families:
  - "JetBrains Mono"
  - 'Single Quoted'

font_size_points: 14
`
	r, err := config.resolve_from_yaml(yaml)
	defer config.resolved_destroy(&r)

	testing.expect(t, errs.ok(err))
	testing.expect(t, len(r.Font_Families) == 2)
	testing.expect(t, r.Font_Families[0] == "JetBrains Mono")
	testing.expect(t, r.Font_Families[1] == "Single Quoted")
	expect_near(t, r.Font_Size_Points, 14.0, "font size")
}

@(test)
test_hex_color_parse :: proc(t: ^testing.T) {
	c, err := config.parse_hex_color("#ff8000")
	testing.expect(t, errs.ok(err))
	expect_near(t, c[0], 1.0, "r")
	expect_near(t, c[1], 128.0 / 255.0, "g")
	expect_near(t, c[2], 0.0, "b")
	expect_near(t, c[3], 1.0, "a")

	_, err = config.parse_hex_color("#fff")
	testing.expect(t, !errs.ok(err))
	errs.destroy(&err)
	_, err = config.parse_hex_color("ff8000")
	testing.expect(t, !errs.ok(err))
	errs.destroy(&err)
	_, err = config.parse_hex_color("#ff80zz")
	testing.expect(t, !errs.ok(err))
	errs.destroy(&err)
}

@(test)
test_generate_source_carries_resolved_values :: proc(t: ^testing.T) {
	r, err := config.resolve_from_yaml("font_size_points: 20\n" + FULL_THEME_YAML)
	defer config.resolved_destroy(&r)
	testing.expect(t, errs.ok(err))

	src := config.generate_source(r)
	defer delete(src)

	// The staged source must carry the resolved values and the generated
	// header so nobody edits it by hand.
	testing.expect(t, src != "")
	testing.expect(t, strings.contains(src, config.GENERATED_HEADER))
	testing.expect(t, strings.contains(src, "package generated"))
	testing.expect(t, strings.contains(src, "Font_Size_Points = 20"))
	testing.expect(t, strings.contains(src, "Source = .Builtin"))
	// 0x11 = 17/255 = 0.06666667 (Odin %v shortest round-trip).
	testing.expect(t, strings.contains(src, "0.06666667"))
}

@(test)
test_describe_summary :: proc(t: ^testing.T) {
	r, err := config.builtin()
	defer config.resolved_destroy(&r)
	testing.expect(t, errs.ok(err))

	s := config.describe(r)
	defer delete(s)
	testing.expect(t, strings.contains(s, "builtin defaults"))
	testing.expect(t, strings.contains(s, "body_bg=#161616"))
}
