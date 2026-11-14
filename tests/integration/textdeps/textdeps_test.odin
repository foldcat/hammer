package textdeps_test

import "core:testing"

import ft "hammer:text/freetype"
import hb "hammer:text/harfbuzz"
import icu "hammer:text/icu"

@(test)
test_freetype_version_and_lifecycle :: proc(t: ^testing.T) {
	library: ft.Library
	err := ft.FT_Init_FreeType(&library)
	testing.expectf(t, err == 0, "FT_Init_FreeType failed: %d", err)
	if err != 0 {
		return
	}
	defer ft.FT_Done_FreeType(library)

	major, minor, patch: i32
	ft.FT_Library_Version(library, &major, &minor, &patch)
	testing.expectf(
		t,
		major == ft.EXPECTED_MAJOR && minor == ft.EXPECTED_MINOR && patch == ft.EXPECTED_PATCH,
		"FreeType pin mismatch: got %d.%d.%d",
		major,
		minor,
		patch,
	)

	invalid_font := [4]u8{0, 1, 2, 3}
	face: ft.Face
	err = ft.FT_New_Memory_Face(library, raw_data(invalid_font[:]), ft.Long(len(invalid_font)), 0, &face)
	testing.expect(t, err != 0)
	testing.expect(t, face == nil)
	if face != nil {
		ft.FT_Done_Face(face)
	}
}

@(test)
test_harfbuzz_version_buffer_and_shape :: proc(t: ^testing.T) {
	major, minor, micro: u32
	hb.hb_version(&major, &minor, &micro)
	testing.expectf(
		t,
		major == hb.EXPECTED_MAJOR && minor == hb.EXPECTED_MINOR && micro == hb.EXPECTED_MICRO,
		"HarfBuzz pin mismatch: got %d.%d.%d",
		major,
		minor,
		micro,
	)
	testing.expect(t, hb.hb_version_string() == hb.EXPECTED_VERSION_STRING)
	testing.expect(t, hb.hb_version_atleast(hb.EXPECTED_MAJOR, hb.EXPECTED_MINOR, hb.EXPECTED_MICRO) != 0)

	buffer := hb.hb_buffer_create()
	testing.expect(t, buffer != nil)
	if buffer == nil {
		return
	}
	defer hb.hb_buffer_destroy(buffer)

	text := "A\u0301"
	hb.hb_buffer_add_utf8(buffer, raw_data(text), i32(len(text)), 0, i32(len(text)))
	hb.hb_buffer_guess_segment_properties(buffer)
	props: hb.Segment_Properties
	hb.hb_buffer_get_segment_properties(buffer, &props)
	testing.expect(t, props.direction == .LTR)
	testing.expect(t, hb.hb_buffer_get_length(buffer) == 2)

	font := hb.hb_font_get_empty()
	testing.expect(t, font != nil)
	hb.hb_shape(font, buffer, nil, 0)

	info_count: u32
	infos := hb.hb_buffer_get_glyph_infos(buffer, &info_count)
	testing.expect(t, info_count == 2)
	testing.expect(t, infos != nil)
	if info_count == 2 && infos != nil {
		testing.expect(t, infos[0].cluster == 0)
		testing.expect(t, infos[1].cluster == 1)
	}

	position_count: u32
	positions := hb.hb_buffer_get_glyph_positions(buffer, &position_count)
	testing.expect(t, position_count == info_count)
	testing.expect(t, positions != nil)
}

@(test)
test_icu_version_graphemes_and_words :: proc(t: ^testing.T) {
	version: icu.Version_Info
	icu.u_getVersion(&version)
	testing.expectf(
		t,
		version == icu.Version_Info{icu.EXPECTED_MAJOR, icu.EXPECTED_MINOR, icu.EXPECTED_PATCH, 0},
		"ICU pin mismatch: got %v",
		version,
	)
	unicode_version: icu.Version_Info
	icu.u_getUnicodeVersion(&unicode_version)
	testing.expect(t, unicode_version == icu.Version_Info{icu.EXPECTED_UNICODE_MAJOR, icu.EXPECTED_UNICODE_MINOR, 0, 0})

	text := [?]icu.UChar{'a', 0x0301, 'b', 0xd83d, 0xdc69, 0x200d, 0xd83d, 0xdcbb}
	status := icu.ZERO_ERROR
	breaks := icu.ubrk_open(.Character, "", raw_data(text[:]), i32(len(text)), &status)
	testing.expect(t, icu.success(status))
	testing.expect(t, breaks != nil)
	if breaks != nil {
		defer icu.ubrk_close(breaks)
		testing.expect(t, icu.ubrk_first(breaks) == 0)
		expected_boundaries := [4]i32{2, 3, 8, icu.DONE}
		for expected in expected_boundaries {
			testing.expectf(t, icu.ubrk_next(breaks) == expected, "grapheme boundary: expected %d", expected)
		}
	}

	words := [?]icu.UChar{'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd'}
	status = icu.ZERO_ERROR
	word_breaks := icu.ubrk_open(.Word, "", raw_data(words[:]), i32(len(words)), &status)
	testing.expect(t, icu.success(status))
	testing.expect(t, word_breaks != nil)
	if word_breaks != nil {
		defer icu.ubrk_close(word_breaks)
		testing.expect(t, icu.ubrk_first(word_breaks) == 0)
		expected_boundaries := [4]i32{5, 6, 11, icu.DONE}
		for expected in expected_boundaries {
			testing.expectf(t, icu.ubrk_next(word_breaks) == expected, "word boundary: expected %d", expected)
		}
	}
}

@(test)
test_icu_bidi_and_properties :: proc(t: ^testing.T) {
	text := [?]icu.UChar{'a', 'b', 'c', ' ', 0x05d0, 0x05d1, 0x05d2}
	status := icu.ZERO_ERROR
	bidi := icu.ubidi_open()
	testing.expect(t, bidi != nil)
	if bidi == nil {
		return
	}
	defer icu.ubidi_close(bidi)

	icu.ubidi_setPara(bidi, raw_data(text[:]), i32(len(text)), icu.DEFAULT_LTR, nil, &status)
	testing.expect(t, icu.success(status))
	testing.expect(t, icu.ubidi_getDirection(bidi) == .Mixed)
	testing.expect(t, icu.ubidi_getParaLevel(bidi) == 0)
	testing.expect(t, icu.ubidi_countRuns(bidi, &status) == 2)
	testing.expect(t, icu.success(status))

	logical_map: [len(text)]i32
	icu.ubidi_getLogicalMap(bidi, raw_data(logical_map[:]), &status)
	testing.expect(t, icu.success(status))
	testing.expect(t, logical_map == [len(text)]i32{0, 1, 2, 3, 6, 5, 4})
	testing.expect(t, icu.ubidi_getVisualIndex(bidi, 4, &status) == 6)
	testing.expect(t, icu.ubidi_getLogicalIndex(bidi, 6, &status) == 4)
	testing.expect(t, icu.success(status))

	testing.expect(t, icu.u_charType('A') == .Uppercase_Letter)
	testing.expect(t, icu.u_charType(0x0301) == .Non_Spacing_Mark)
	testing.expect(t, icu.u_hasBinaryProperty('A', icu.ALPHABETIC) != 0)
	testing.expect(t, icu.u_hasBinaryProperty(' ', icu.WHITE_SPACE) != 0)
	testing.expect(t, icu.u_hasBinaryProperty(0x200e, icu.BIDI_CONTROL) != 0)
}
