package filecodec_test

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:unicode/utf8"

import errs "hammer:core/errs"
import filecodec "hammer:core/filecodec"
import fileload "hammer:core/fileload"

Wide_Conversion_Case :: struct {
	data: string
}

Lossy_Conversion_Case :: struct {
	data:         string,
	want:         string,
	replacements: int,
}

@(test)
test_convert_valid_utf8_copies_content_without_bom :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbfalpha\r\nβ")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 2)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)

	conversion, err := filecodec.convert_to_utf8(decoded, {}, context.allocator)
	testing.expect(t, err == .None)
	defer filecodec.conversion_destroy(&conversion)
	testing.expect(t, string(conversion.text) == "alpha\r\nβ")
	testing.expect(t, !conversion.lossy)
	testing.expect(t, conversion.replacements == 0)
	expect_stream(t, decoded.raw, transmute([]byte)data)
}

@(test)
test_convert_invalid_utf8_requires_deliberate_loss :: proc(t: ^testing.T) {
	data := string("A\x80\xc2B")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)

	refused, err := filecodec.convert_to_utf8(decoded, {}, context.allocator)
	testing.expect(t, err == .Lossy_Confirmation_Required)
	testing.expect(t, len(refused.text) == 0)
	expect_stream(t, decoded.raw, transmute([]byte)data)
	testing.expect(t, !filecodec.can_edit(decoded))

	conversion, convert_err := filecodec.convert_to_utf8(decoded, {allow_lossy = true}, context.allocator)
	testing.expect(t, convert_err == .None)
	defer filecodec.conversion_destroy(&conversion)
	testing.expect(t, string(conversion.text) == "A\xef\xbf\xbd\xef\xbf\xbdB")
	testing.expect(t, conversion.lossy)
	testing.expect(t, conversion.replacements == 2)
	testing.expect(t, utf8.valid_string(string(conversion.text)))
	expect_stream(t, decoded.raw, transmute([]byte)data)
	testing.expect(t, !filecodec.can_edit(decoded))
}

@(test)
test_convert_well_formed_utf16_and_utf32_is_lossless :: proc(t: ^testing.T) {
	cases := []Wide_Conversion_Case {
		{data = "\xff\xfeA\x00\xb2\x03\x3d\xd8\x00\xde\n\x00"},
		{data = "\xfe\xff\x00A\x03\xb2\xd8\x3d\xde\x00\x00\n"},
		{data = "\xff\xfe\x00\x00A\x00\x00\x00\xb2\x03\x00\x00\x00\xf6\x01\x00\n\x00\x00\x00"},
		{data = "\x00\x00\xfe\xff\x00\x00\x00A\x00\x00\x03\xb2\x00\x01\xf6\x00\x00\x00\x00\n"},
	}
	for c in cases {
		data := c.data
		for chunk_size in 1 ..= 5 {
			loaded: fileload.Loaded
			loaded_from_bytes(t, &loaded, transmute([]byte)data, chunk_size)
			defer fileload.loaded_destroy(&loaded)
			decoded := filecodec.decode_loaded(&loaded)
			testing.expect(t, decoded.status == .Unsupported_Encoding)
			testing.expect(t, !filecodec.can_edit(decoded))

			conversion, err := filecodec.convert_to_utf8(decoded, {}, context.allocator)
			testing.expect(t, err == .None)
			defer filecodec.conversion_destroy(&conversion)
			testing.expectf(t, string(conversion.text) == "Aβ😀\n", "wide conversion mismatch: %q", string(conversion.text))
			testing.expect(t, !conversion.lossy)
			testing.expect(t, conversion.replacements == 0)
			testing.expect(t, utf8.valid_string(string(conversion.text)))
			expect_stream(t, decoded.raw, transmute([]byte)data)
			testing.expect(t, !filecodec.can_edit(decoded))
		}
	}
}

@(test)
test_convert_malformed_wide_input_requires_deliberate_loss :: proc(t: ^testing.T) {
	cases := []Lossy_Conversion_Case {
		{data = "\xff\xfe\x3d\xd8A\x00\x00", want = "\xef\xbf\xbdA\xef\xbf\xbd", replacements = 2},
		{data = "\xfe\xff\xdc\x00", want = "\xef\xbf\xbd", replacements = 1},
		{data = "\xff\xfe\x00\x00\x00\xd8\x00\x00\xff\xff\x11\x00\x01", want = "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd", replacements = 3},
		{data = "\x00\x00\xfe\xff\x00\x11\x00\x00", want = "\xef\xbf\xbd", replacements = 1},
	}
	for c in cases {
		data := c.data
		for chunk_size in 1 ..= 5 {
			loaded: fileload.Loaded
			loaded_from_bytes(t, &loaded, transmute([]byte)data, chunk_size)
			defer fileload.loaded_destroy(&loaded)
			decoded := filecodec.decode_loaded(&loaded)
			testing.expect(t, decoded.status == .Unsupported_Encoding)

			_, err := filecodec.convert_to_utf8(decoded, {}, context.allocator)
			testing.expect(t, err == .Lossy_Confirmation_Required)
			conversion, convert_err := filecodec.convert_to_utf8(decoded, {allow_lossy = true}, context.allocator)
			testing.expect(t, convert_err == .None)
			defer filecodec.conversion_destroy(&conversion)
			testing.expectf(t, string(conversion.text) == c.want, "lossy wide conversion mismatch: %q", string(conversion.text))
			testing.expect(t, conversion.lossy)
			testing.expect(t, conversion.replacements == c.replacements)
			testing.expect(t, utf8.valid_string(string(conversion.text)))
			expect_stream(t, decoded.raw, transmute([]byte)data)
		}
	}
}

@(test)
test_conversion_output_is_always_valid_utf8_on_random_input :: proc(t: ^testing.T) {
	state := u64(0x9e3779b97f4a7c15)
	for case_index in 0 ..< 1000 {
		state = xorshift64(state)
		n := int(state % 49)
		data := make([]byte, n, context.allocator)
		for i in 0 ..< n {
			state = xorshift64(state)
			data[i] = byte(state >> 32)
		}
		state = xorshift64(state)
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, data, 1 + int(state % 8))
		decoded := filecodec.decode_loaded(&loaded)

		if decoded.status != .Valid_UTF8 {
			_, err := filecodec.convert_to_utf8(decoded, {}, context.allocator)
			if decoded.status == .Invalid_UTF8 {
				testing.expect(t, err == .Lossy_Confirmation_Required)
			}
		}
		conversion, err := filecodec.convert_to_utf8(decoded, {allow_lossy = true}, context.allocator)
		testing.expectf(t, err == .None, "conversion failed in random case %d", case_index)
		if err == .None {
			testing.expectf(t, utf8.valid_string(string(conversion.text)), "invalid conversion output in random case %d", case_index)
			if decoded.status == .Valid_UTF8 {
				testing.expect(t, string(conversion.text) == string(data))
			}
			filecodec.conversion_destroy(&conversion)
		}
		expect_stream(t, decoded.raw, data)
		fileload.loaded_destroy(&loaded)
		delete(data)
	}
}

@(test)
test_display_and_conversion_allocation_failure_is_clean :: proc(t: ^testing.T) {
	data := string("A\x80B\xffC")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)

	buffer := make([]byte, 48, context.allocator)
	defer delete(buffer)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_buffer(&arena, buffer) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	display, display_err := filecodec.display_make(decoded, allocator)
	if display_err == .None {
		filecodec.display_destroy(&display)
	}
	testing.expect(t, display_err == .Out_Of_Memory)
	conversion, conversion_err := filecodec.convert_to_utf8(decoded, {allow_lossy = true}, allocator)
	if conversion_err == .None {
		filecodec.conversion_destroy(&conversion)
	}
	testing.expect(t, conversion_err == .Resource_Limit)
	expect_stream(t, decoded.raw, transmute([]byte)data)
}

@(test)
test_real_invalid_load_display_and_conversion_preserve_source :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "hammer-filecodec-display-*", context.temp_allocator)
	if dir_err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", dir_err)
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/invalid.bin", dir)
	data := string("\xef\xbb\xbfok\n\xffend")
	if err := os.write_entire_file(path, transmute([]byte)data); err != nil {
		testing.expectf(t, false, "cannot write fixture: %v", err)
		return
	}
	loaded: fileload.Loaded
	load_err := fileload.load_file(&loaded, path, {chunk_size = 1}, context.allocator)
	if !errs.ok(load_err) {
		desc := errs.describe(load_err, context.allocator)
		testing.expectf(t, false, "load failed: %s", desc)
		delete(desc, context.allocator)
		errs.destroy(&load_err)
		return
	}
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)
	display, display_err := filecodec.display_make(decoded, context.allocator)
	testing.expect(t, display_err == .None)
	defer filecodec.display_destroy(&display)
	testing.expect(t, string(display.text) == "ok\n\\xffend")
	testing.expect(t, filecodec.parser_mode(decoded) == .Plain_Text)

	_, refused := filecodec.convert_to_utf8(decoded, {}, context.allocator)
	testing.expect(t, refused == .Lossy_Confirmation_Required)
	conversion, convert_err := filecodec.convert_to_utf8(decoded, {allow_lossy = true}, context.allocator)
	testing.expect(t, convert_err == .None)
	defer filecodec.conversion_destroy(&conversion)
	testing.expect(t, string(conversion.text) == "ok\n\xef\xbf\xbdend")
	expect_stream(t, decoded.raw, transmute([]byte)data)
}
