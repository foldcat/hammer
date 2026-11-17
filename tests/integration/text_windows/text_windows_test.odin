#+build windows

package text_windows_test

import "core:os"
import "core:testing"

import errs "hammer:core/errs"
import dw "hammer:text/directwrite"
import fonts "hammer:text/fonts"
import glyphcache "hammer:text/glyphcache"
import shaping "hammer:text/shaping"

FIXTURE_FONT :: #directory + "/../textdeps/fixtures/FixtureMono.ttf"

@(rodata)
BODY_FAMILIES := []string{"Definitely Missing Hammer Font", "monospace"}
@(rodata)
TAG_FAMILIES := []string{"Consolas"}
@(rodata)
MONOSPACE_FAMILIES := []string{"monospace"}

expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	description := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected error: %s", description)
	delete(description, context.allocator)
	owned := err
	errs.destroy(&owned)
	return false
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	if err.kind != kind {
		description := errs.describe(err, context.allocator)
		testing.expectf(t, false, "got %v, want %v: %s", err.kind, kind, description)
		delete(description, context.allocator)
	}
	owned := err
	errs.destroy(&owned)
}

system_options :: proc() -> fonts.Options {
	options: fonts.Options
	options.roles[int(fonts.Role.Body)].families = BODY_FAMILIES
	options.roles[int(fonts.Role.Tag)].families = TAG_FAMILIES
	options.roles[int(fonts.Role.Console)].families = MONOSPACE_FAMILIES
	return options
}

fixture_options :: proc() -> fonts.Options {
	options: fonts.Options
	for role_index in 0 ..< 3 {
		options.roles[role_index].path = FIXTURE_FONT
	}
	return options
}

@(test)
test_system_font_discovery_and_real_glyph_lookup :: proc(t: ^testing.T) {
	set: fonts.Set
	if !expect_ok(t, fonts.init(&set, system_options())) {
		return
	}
	defer fonts.destroy(&set)
	for role_index in 0 ..< 3 {
		role := fonts.Role(role_index)
		selected := fonts.face(&set, role)
		if !testing.expect(t, selected != nil) {
			continue
		}
		testing.expect(t, selected.family == "Consolas")
		testing.expect(t, selected.path != "" && os.exists(selected.path))
		native := cast(^dw.Native_Face)selected.native
		points := [1]u32{'A'}
		indices := [1]u16{}
		status := native.face.vtable.get_glyph_indices(native.face, raw_data(points[:]), 1, raw_data(indices[:]))
		testing.expect(t, dw.succeeded(status) && indices[0] != 0)
	}
}

@(test)
test_explicit_font_and_codepoint_fallback :: proc(t: ^testing.T) {
	set: fonts.Set
	if !expect_ok(t, fonts.init(&set, fixture_options())) {
		return
	}
	defer fonts.destroy(&set)
	for role_index in 0 ..< 3 {
		role := fonts.Role(role_index)
		selected := fonts.face(&set, role)
		testing.expect(t, selected != nil && selected.face_index == 0)
	}
	fallback, err := fonts.ensure_fallback(&set, 0x05d0)
	if !expect_ok(t, err) || !testing.expect(t, fallback != nil) {
		return
	}
	testing.expect(t, fallback.cache_id > fonts.ROLE_COUNT && fallback.path != "")
	again, again_err := fonts.ensure_fallback(&set, 0x05d0)
	expect_ok(t, again_err)
	testing.expect(t, again == fallback && set.fallback_count == 1)
	missing, missing_err := fonts.ensure_fallback(&set, 0x0378)
	expect_ok(t, missing_err)
	testing.expect(t, missing == nil && set.miss_count == 1)
	invalid, invalid_err := fonts.ensure_fallback(&set, 0xd800)
	expect_kind(t, invalid_err, .Invalid_Input)
	testing.expect(t, invalid == nil)
}

@(test)
test_font_failures_clean_partial_initialization :: proc(t: ^testing.T) {
	options := system_options()
	options.roles[int(fonts.Role.Tag)].families = []string{"Definitely Missing Hammer Font"}
	set: fonts.Set
	expect_kind(t, fonts.init(&set, options), .NotFound)
	for role_index in 0 ..< fonts.ROLE_COUNT {
		role := fonts.Role(role_index)
		testing.expect(t, fonts.face(&set, role) == nil)
	}
	fonts.destroy(&set)

	options = fixture_options()
	options.roles[int(fonts.Role.Body)].path = "definitely-missing-hammer-font.ttf"
	expect_kind(t, fonts.init(&set, options), .IO)
	testing.expect(t, fonts.face(&set, .Body) == nil)
	fonts.destroy(&set)
}


@(test)
test_directwrite_shaping_and_alpha_rasterization :: proc(t: ^testing.T) {
	set: fonts.Set
	if !expect_ok(t, fonts.init(&set, fixture_options())) {
		return
	}
	defer fonts.destroy(&set)
	body := fonts.face(&set, .Body)
	if !testing.expect(t, body != nil) {
		return
	}
	font_list := [1]shaping.Font{{font_id = body.cache_id, face_index = body.face_index, native = body.native}}
	text, err := shaping.shape("A e\u0301fi", font_list[:], {pixel_size = 16, ligatures = true})
	if !expect_ok(t, err) {
		return
	}
	defer shaping.destroy(&text)
	testing.expect(t, len(text.runs) > 0 && text.total_advance > 0)
	testing.expect(t, len(text.missing) == 0)
	for run in text.runs {
		testing.expect(t, len(run.glyphs) > 0 && len(run.clusters) == 5)
	}

	glyph, lookup_err := glyphcache.native_char_index(body.native, 'A')
	if !expect_ok(t, lookup_err) || !testing.expect(t, glyph != 0) {
		return
	}
	bitmap, raster_err := glyphcache.native_rasterize(body.native, {font_id = body.cache_id, glyph_id = glyph, pixel_size = 16})
	if !expect_ok(t, raster_err) {
		return
	}
	if bitmap.owned {
		defer delete(bitmap.pixels)
	}
	testing.expect(t, bitmap.width > 0 && bitmap.height > 0 && bitmap.pitch >= bitmap.width)
	nonzero := false
	for pixel in bitmap.pixels {
		nonzero = nonzero || pixel != 0
	}
	testing.expect(t, nonzero)
}


@(test)
test_bidi_runs_use_visual_grapheme_order :: proc(t: ^testing.T) {
	set: fonts.Set
	if !expect_ok(t, fonts.init(&set, system_options())) {
		return
	}
	defer fonts.destroy(&set)
	body := fonts.face(&set, .Body)
	if !testing.expect(t, body != nil) {
		return
	}
	samples := [2]struct{text: string, codepoint: rune}{{"אבג", 0x05d0}, {"مرحبا", 0x0645}}
	for sample in samples {
		fallback, fallback_err := fonts.ensure_fallback(&set, sample.codepoint)
		if !expect_ok(t, fallback_err) || !testing.expect(t, fallback != nil) {
			continue
		}
		font_list := [2]shaping.Font{
			{font_id = body.cache_id, face_index = body.face_index, native = body.native},
			{font_id = fallback.cache_id, face_index = fallback.face_index, native = fallback.native},
		}
		font_count := 1 if fallback == body else 2
		text, err := shaping.shape(sample.text, font_list[:font_count], {pixel_size = 16})
		if !expect_ok(t, err) {
			continue
		}
		defer shaping.destroy(&text)
		testing.expect(t, len(text.runs) > 0 && len(text.missing) == 0)
		for run in text.runs {
			testing.expect(t, run.direction == .RTL)
			for index in 1 ..< len(run.clusters) {
				testing.expect(t, run.clusters[index].source_start < run.clusters[index - 1].source_start)
			}
		}
	}
}

@(test)
test_ligature_option_controls_directwrite_features :: proc(t: ^testing.T) {
	options := fixture_options()
	for role_index in 0 ..< 3 {
		options.roles[role_index].path = #directory + "/../textdeps/fixtures/FixtureLigature.ttf"
	}
	set: fonts.Set
	if !expect_ok(t, fonts.init(&set, options)) {
		return
	}
	defer fonts.destroy(&set)
	body := fonts.face(&set, .Body)
	if !testing.expect(t, body != nil) {
		return
	}
	font_list := [1]shaping.Font{{font_id = body.cache_id, face_index = body.face_index, native = body.native}}
	enabled, enabled_err := shaping.shape("fi", font_list[:], {pixel_size = 16, ligatures = true})
	if !expect_ok(t, enabled_err) {
		return
	}
	defer shaping.destroy(&enabled)
	disabled, disabled_err := shaping.shape("fi", font_list[:], {pixel_size = 16, ligatures = false})
	if !expect_ok(t, disabled_err) {
		return
	}
	defer shaping.destroy(&disabled)
	enabled_count := 0
	disabled_count := 0
	for run in enabled.runs {
		enabled_count += len(run.glyphs)
	}
	for run in disabled.runs {
		disabled_count += len(run.glyphs)
	}
	testing.expectf(t, enabled_count == 1 && disabled_count == 2, "glyph counts: enabled=%d disabled=%d", enabled_count, disabled_count)
}
