package filecodec_test

import "core:testing"
import "core:unicode/utf8"

import filecodec "hammer:core/filecodec"
import fileload "hammer:core/fileload"

@(test)
test_display_valid_utf8_is_identity_with_raw_offsets :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbfAβ\n")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)

	display, err := filecodec.display_make(decoded, context.allocator)
	testing.expect(t, err == .None)
	defer filecodec.display_destroy(&display)
	testing.expect(t, string(display.text) == "Aβ\n")
	testing.expect(t, utf8.valid_string(string(display.text)))
	testing.expect(t, len(display.offsets) == 1)
	testing.expect(t, display.offsets[0].kind == .Literal)

	display_offset, ok := filecodec.raw_to_display(display, 2)
	testing.expect(t, !ok && display_offset == 0)
	display_offset, ok = filecodec.raw_to_display(display, 3)
	testing.expect(t, ok && display_offset == 0)
	display_offset, ok = filecodec.raw_to_display(display, 5)
	testing.expect(t, ok && display_offset == 2)
	raw_offset: int
	raw_offset, ok = filecodec.display_to_raw(display, 2)
	testing.expect(t, ok && raw_offset == 5)
	display_offset, ok = filecodec.raw_to_display(display, len(data))
	testing.expect(t, ok && display_offset == len(display.text))
	raw_offset, ok = filecodec.display_to_raw(display, len(display.text))
	testing.expect(t, ok && raw_offset == len(data))
}

@(test)
test_display_invalid_utf8_escapes_bytes_and_maps_every_boundary :: proc(t: ^testing.T) {
	data := string("A\x80\xc2\xe0\xa0\x80B")
	want := string("A\\x80\\xc2\xe0\xa0\x80B")
	for chunk_size in 1 ..= 5 {
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, transmute([]byte)data, chunk_size)
		defer fileload.loaded_destroy(&loaded)
		decoded := filecodec.decode_loaded(&loaded)
		testing.expect(t, decoded.status == .Invalid_UTF8)
		testing.expect(t, !filecodec.can_edit(decoded))
		testing.expect(t, filecodec.parser_mode(decoded) == .Plain_Text)

		display, err := filecodec.display_make(decoded, context.allocator)
		testing.expect(t, err == .None)
		defer filecodec.display_destroy(&display)
		testing.expectf(t, string(display.text) == want, "display mismatch at chunk size %d: %q", chunk_size, string(display.text))
		testing.expect(t, utf8.valid_string(string(display.text)))
		testing.expect(t, len(display.offsets) == 3)
		testing.expect(t, display.offsets[0].kind == .Literal)
		testing.expect(t, display.offsets[1].kind == .Escaped)
		testing.expect(t, display.offsets[1].raw_length == 2)
		testing.expect(t, display.offsets[1].display_length == 8)
		testing.expect(t, display.offsets[2].kind == .Literal)
		expect_stream(t, decoded.raw, transmute([]byte)data)

		for raw_offset in 0 ..= len(data) {
			display_offset, ok := filecodec.raw_to_display(display, raw_offset)
			testing.expectf(t, ok, "raw offset %d unmapped at chunk size %d", raw_offset, chunk_size)
			roundtrip, reverse_ok := filecodec.display_to_raw(display, display_offset)
			testing.expectf(t, reverse_ok && roundtrip == raw_offset, "offset roundtrip failed: raw %d -> display %d -> raw %d", raw_offset, display_offset, roundtrip)
		}
		for display_offset in 0 ..= len(display.text) {
			raw_offset: int
			ok: bool
			raw_offset, ok = filecodec.display_to_raw(display, display_offset)
			if display_offset >= 1 && display_offset < 9 && (display_offset - 1) % 4 != 0 {
				testing.expect(t, !ok, "escape interior unexpectedly mapped")
			} else if testing.expect(t, ok) {
				mapped_display, forward_ok := filecodec.raw_to_display(display, raw_offset)
				testing.expect(t, forward_ok && mapped_display == display_offset)
			}
		}
	}
}

@(test)
test_display_unsupported_encoding_is_explicit_read_only_byte_view :: proc(t: ^testing.T) {
	data := string("\xff\xfeA\x00")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)
	display, err := filecodec.display_make(decoded, context.allocator)
	testing.expect(t, err == .None)
	defer filecodec.display_destroy(&display)

	testing.expect(t, string(display.text) == "\\xff\\xfe\\x41\\x00")
	testing.expect(t, utf8.valid_string(string(display.text)))
	testing.expect(t, len(display.offsets) == 1)
	testing.expect(t, display.offsets[0].kind == .Escaped)
	testing.expect(t, display.offsets[0].raw_start == 0)
	testing.expect(t, display.offsets[0].raw_length == len(data))
	testing.expect(t, !filecodec.can_edit(decoded))
	testing.expect(t, filecodec.parser_mode(decoded) == .Disabled)
	expect_stream(t, decoded.raw, transmute([]byte)data)

	display_offset, ok := filecodec.raw_to_display(display, 3)
	testing.expect(t, ok && display_offset == 12)
	raw_offset: int
	raw_offset, ok = filecodec.display_to_raw(display, 12)
	testing.expect(t, ok && raw_offset == 3)
	_, ok = filecodec.display_to_raw(display, 13)
	testing.expect(t, !ok)
	_, ok = filecodec.raw_to_display(display, len(data) + 1)
	testing.expect(t, !ok)
}

@(test)
test_display_empty_bom_only_has_only_end_mapping :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbf")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)
	display, err := filecodec.display_make(decoded, context.allocator)
	testing.expect(t, err == .None)
	defer filecodec.display_destroy(&display)

	testing.expect(t, len(display.text) == 0)
	testing.expect(t, len(display.offsets) == 0)
	testing.expect(t, filecodec.parser_mode(decoded) == .UTF8)
	display_offset, ok := filecodec.raw_to_display(display, 3)
	testing.expect(t, ok && display_offset == 0)
	raw_offset: int
	raw_offset, ok = filecodec.display_to_raw(display, 0)
	testing.expect(t, ok && raw_offset == 3)
	_, ok = filecodec.raw_to_display(display, 2)
	testing.expect(t, !ok)
	_, ok = filecodec.display_to_raw(display, 1)
	testing.expect(t, !ok)
}
