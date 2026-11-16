package textdeps_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import errs "hammer:core/errs"
import fonts "hammer:text/fonts"
import ft "hammer:text/freetype"

FIXTURE_DIR :: #directory + "fixtures"
FIXTURE_FONT :: FIXTURE_DIR + "/FixtureMono.ttf"

@(rodata)
BODY_FAMILIES := []string{"Definitely Missing Hammer Font", "Noto Sans Mono"}
@(rodata)
TAG_FAMILIES := []string{"monospace"}
@(rodata)
MISSING_FAMILIES := []string{"Definitely Missing Hammer Font"}

write_fontconfig :: proc(t: ^testing.T, sandbox: string) -> string {
	cache := fmt.tprintf("%s/cache", sandbox)
	if err := os.make_directory_all(cache); err != nil {
		testing.expectf(t, false, "cannot create font cache sandbox: %v", err)
		return ""
	}
	path := fmt.tprintf("%s/fonts.conf", sandbox)
	contents := fmt.aprintf(
		`<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>%s</dir>
  <cachedir>%s</cachedir>
  <alias><family>monospace</family><prefer><family>Noto Sans Mono</family></prefer></alias>
</fontconfig>
`,
		FIXTURE_DIR,
		cache,
	)
	defer delete(contents)
	if err := os.write_entire_file(path, transmute([]byte)contents); err != nil {
		testing.expectf(t, false, "cannot write isolated fontconfig: %v", err)
		return ""
	}
	return path
}

font_options :: proc(config_path: string) -> fonts.Options {
	options: fonts.Options
	options.config_path = config_path
	options.roles[int(fonts.Role.Body)] = {families = BODY_FAMILIES}
	options.roles[int(fonts.Role.Tag)] = {families = TAG_FAMILIES}
	options.roles[int(fonts.Role.Console)] = {path = FIXTURE_FONT}
	return options
}

expect_font_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	desc := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected font error: %s", desc)
	delete(desc, context.allocator)
	owned := err
	errs.destroy(&owned)
	return false
}

expect_font_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	if err.kind != kind {
		desc := errs.describe(err, context.allocator)
		testing.expectf(t, false, "font error: got %v, want %v: %s", err.kind, kind, desc)
		delete(desc, context.allocator)
	}
	owned := err
	errs.destroy(&owned)
}

@(test)
test_font_discovery_roles_and_real_glyph :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-fonts-*", context.temp_allocator)
	if !testing.expectf(t, sandbox_err == nil, "cannot create font sandbox: %v", sandbox_err) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}

	set: fonts.Set
	if !expect_font_ok(t, fonts.init(&set, font_options(config_path))) {
		return
	}
	defer fonts.destroy(&set)

	body := fonts.face(&set, .Body)
	tag := fonts.face(&set, .Tag)
	console := fonts.face(&set, .Console)
	if !testing.expect(t, body != nil && tag != nil && console != nil) {
		return
	}
	testing.expect(t, body.family == "Noto Sans Mono")
	testing.expect(t, tag.family == "Noto Sans Mono")
	testing.expect(t, console.family == "Noto Sans Mono")
	testing.expectf(t, body.path == FIXTURE_FONT && tag.path == FIXTURE_FONT && console.path == FIXTURE_FONT, "paths: body=%q tag=%q console=%q fixture=%q", body.path, tag.path, console.path, FIXTURE_FONT)
	testing.expect(t, body.face_index == 0 && tag.face_index == 0 && console.face_index == 0)
	testing.expect(t, body.native != tag.native && body.native != console.native && tag.native != console.native)

	ft_face := ft.Face(body.native)
	testing.expect(t, ft.FT_Set_Pixel_Sizes(ft_face, 0, 16) == 0)
	testing.expect(t, ft.FT_Load_Char(ft_face, 'A', ft.LOAD_DEFAULT | ft.LOAD_RENDER) == 0)
	testing.expect(t, ft_face.glyph != nil)
	if ft_face.glyph != nil {
		testing.expect(t, ft_face.glyph.bitmap.width > 0)
		testing.expect(t, ft_face.glyph.bitmap.rows > 0)
		testing.expect(t, ft_face.glyph.bitmap.buffer != nil)
	}
}

@(test)
test_font_missing_family_cleans_partial_roles :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-fonts-missing-*", context.temp_allocator)
	if !testing.expectf(t, sandbox_err == nil, "cannot create font sandbox: %v", sandbox_err) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}
	options := font_options(config_path)
	options.roles[int(fonts.Role.Tag)] = {families = MISSING_FAMILIES}

	set: fonts.Set
	err := fonts.init(&set, options)
	expect_font_kind(t, err, .NotFound)
	roles := [?]fonts.Role{.Body, .Tag, .Console}
	for role in roles {
		testing.expect(t, fonts.face(&set, role) == nil)
	}
	fonts.destroy(&set)
}

@(test)
test_font_explicit_path_failure_is_not_substituted :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-fonts-path-*", context.temp_allocator)
	if !testing.expectf(t, sandbox_err == nil, "cannot create font sandbox: %v", sandbox_err) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}
	options := font_options(config_path)
	options.roles[int(fonts.Role.Body)] = {path = strings.concatenate([]string{sandbox, "/missing.ttf"}, context.allocator)}
	defer delete(options.roles[int(fonts.Role.Body)].path)

	set: fonts.Set
	err := fonts.init(&set, options)
	expect_font_kind(t, err, .IO)
	testing.expect(t, fonts.face(&set, .Body) == nil)
	fonts.destroy(&set)
}

@(test)
test_codepoint_font_fallback_and_misses_are_cached :: proc(t: ^testing.T) {
	sandbox, sandbox_err := os.make_directory_temp("", "hammer-font-fallback-*", context.temp_allocator)
	if !testing.expect(t, sandbox_err == nil) {
		return
	}
	defer os.remove_all(sandbox)
	config_path := write_fontconfig(t, sandbox)
	if config_path == "" {
		return
	}
	options := font_options(config_path)
	options.roles[int(fonts.Role.Tag)] = {path = FIXTURE_HEBREW_FONT}
	set: fonts.Set
	if !expect_font_ok(t, fonts.init(&set, options)) {
		return
	}
	defer fonts.destroy(&set)

	hebrew, err := fonts.ensure_fallback(&set, 0x05d0)
	if !expect_font_ok(t, err) || !testing.expect(t, hebrew != nil) {
		return
	}
	testing.expect(t, hebrew.path == FIXTURE_HEBREW_FONT && hebrew.cache_id > fonts.ROLE_COUNT)
	testing.expect(t, hebrew != fonts.face(&set, .Tag))
	arabic, arabic_err := fonts.ensure_fallback(&set, 0x0645)
	if !expect_font_ok(t, arabic_err) || !testing.expect(t, arabic != nil) {
		return
	}
	testing.expect(t, arabic.path == FIXTURE_ARABIC_FONT && arabic.cache_id != hebrew.cache_id)
	testing.expect(t, set.fallback_count == 2)

	again, again_err := fonts.ensure_fallback(&set, 0x05d0)
	expect_font_ok(t, again_err)
	testing.expect(t, again == hebrew && set.fallback_count == 2)

	missing, missing_err := fonts.ensure_fallback(&set, 0x0378)
	expect_font_ok(t, missing_err)
	testing.expect(t, missing == nil && set.miss_count == 1)
	missing_again, missing_again_err := fonts.ensure_fallback(&set, 0x0378)
	expect_font_ok(t, missing_again_err)
	testing.expect(t, missing_again == nil && set.miss_count == 1)

	invalid, invalid_err := fonts.ensure_fallback(&set, 0xd800)
	expect_font_kind(t, invalid_err, .Invalid_Input)
	testing.expect(t, invalid == nil)
}
