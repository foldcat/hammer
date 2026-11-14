// Tests for M03.03 file encoding/BOM/newline policy. The chunked oracle is
// the original byte slice itself; strict UTF-8 validity is also compared with
// the pinned standard library on deterministic pseudo-random inputs.
package filecodec_test

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:unicode/utf8"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import filecodec "hammer:core/filecodec"
import fileload "hammer:core/fileload"
import rope "hammer:core/rope"

Newline_Case :: struct {
	data:   string,
	style:  filecodec.Newline,
	lf:     int,
	crlf:   int,
	cr:     int,
}

Unsupported_Case :: struct {
	data:     string,
	encoding: filecodec.Encoding,
	bom:      filecodec.BOM,
}

Invalid_Case :: struct {
	data:   string,
	reason: filecodec.Invalid_Reason,
	length: int,
}

loaded_from_bytes :: proc(t: ^testing.T, loaded: ^fileload.Loaded, data: []byte, chunk_size: int) {
	chunk.init(&loaded.store, {chunk_size = chunk_size}, context.allocator)
	loaded.ids = make([dynamic]chunk.Chunk_ID, context.allocator)
	for offset := 0; offset < len(data); {
		n := min(chunk_size, len(data) - offset)
		id, err := chunk.intern(&loaded.store, data[offset:offset + n])
		if !testing.expect(t, err == .None) {
			return
		}
		_, append_err := append(&loaded.ids, id)
		testing.expect(t, append_err == .None)
		offset += n
	}
}

collect_stream :: proc(t: ^testing.T, stream: filecodec.Byte_Stream) -> []byte {
	out := make([]byte, stream.length, context.allocator)
	it := filecodec.stream_iter_init(stream)
	pos := 0
	for {
		span, ok := filecodec.stream_iter_next(&it)
		if !ok {
			break
		}
		copy(out[pos:], span)
		pos += len(span)
	}
	testing.expect(t, pos == len(out))
	return out
}

expect_stream :: proc(t: ^testing.T, stream: filecodec.Byte_Stream, want: []byte) {
	got := collect_stream(t, stream)
	defer delete(got)
	testing.expectf(t, bytes.equal(got, want), "stream mismatch: got %v bytes, want %v", len(got), len(want))
}

@(test)
test_utf8_content_and_raw_are_byte_exact :: proc(t: ^testing.T) {
	data := string("alpha\nβ✓\r\nlast")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 2)
	defer fileload.loaded_destroy(&loaded)

	decoded := filecodec.decode_loaded(&loaded)
	testing.expect(t, decoded.status == .Valid_UTF8)
	testing.expect(t, filecodec.can_edit(decoded))
	testing.expect(t, decoded.metadata.encoding == .UTF8)
	testing.expect(t, decoded.metadata.bom == .None)
	testing.expect(t, decoded.metadata.newline == .Mixed)
	testing.expect(t, decoded.metadata.newlines.lf == 1)
	testing.expect(t, decoded.metadata.newlines.crlf == 1)
	testing.expect(t, decoded.metadata.newlines.cr == 0)
	expect_stream(t, decoded.raw, transmute([]byte)data)
	expect_stream(t, decoded.content, transmute([]byte)data)

	metrics := rope.metrics_of(transmute([]byte)data)
	testing.expect(t, metrics.scalar_count == utf8.rune_count(data))
}

@(test)
test_newline_styles_across_single_byte_chunks :: proc(t: ^testing.T) {
	cases := []Newline_Case {
		{data = "", style = .None},
		{data = "plain", style = .None},
		{data = "a\nb\n", style = .LF, lf = 2},
		{data = "a\r\nb\r\n", style = .CRLF, crlf = 2},
		{data = "a\rb\r", style = .CR, cr = 2},
		{data = "\n\r\n", style = .Mixed, lf = 1, crlf = 1},
		{data = "\r\r\n\n", style = .Mixed, lf = 1, crlf = 1, cr = 1},
		{data = "\r\n\r", style = .Mixed, crlf = 1, cr = 1},
	}
	for c in cases {
		data := c.data
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
		defer fileload.loaded_destroy(&loaded)

		decoded := filecodec.decode_loaded(&loaded)
		testing.expect(t, decoded.status == .Valid_UTF8)
		testing.expectf(t, decoded.metadata.newline == c.style, "wrong newline style for %q", c.data)
		testing.expect(t, decoded.metadata.newlines.lf == c.lf)
		testing.expect(t, decoded.metadata.newlines.crlf == c.crlf)
		testing.expect(t, decoded.metadata.newlines.cr == c.cr)
		expect_stream(t, decoded.content, transmute([]byte)data)
	}
}

@(test)
test_utf8_bom_is_metadata_not_content_at_every_split :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbfA\r\nB")
	for chunk_size in 1 ..= 8 {
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, transmute([]byte)data, chunk_size)
		defer fileload.loaded_destroy(&loaded)

		decoded := filecodec.decode_loaded(&loaded)
		testing.expect(t, decoded.status == .Valid_UTF8)
		testing.expect(t, filecodec.can_edit(decoded))
		testing.expect(t, decoded.metadata.encoding == .UTF8)
		testing.expect(t, decoded.metadata.bom == .UTF8)
		testing.expect(t, decoded.metadata.newline == .CRLF)
		testing.expect(t, decoded.metadata.newlines.crlf == 1)
		testing.expect(t, decoded.raw.length == len(data))
		testing.expect(t, decoded.content.length == len(data) - 3)
		expect_stream(t, decoded.raw, transmute([]byte)data)
		expect_stream(t, decoded.content, transmute([]byte)string("A\r\nB"))
	}
}

@(test)
test_utf8_bom_only_is_empty_valid_content :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbf")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
	defer fileload.loaded_destroy(&loaded)

	decoded := filecodec.decode_loaded(&loaded)
	testing.expect(t, decoded.status == .Valid_UTF8)
	testing.expect(t, decoded.content.length == 0)
	testing.expect(t, decoded.metadata.newline == .None)
	expect_stream(t, decoded.raw, transmute([]byte)data)
	expect_stream(t, decoded.content, {})
}

@(test)
test_unicode_boms_are_explicitly_unsupported :: proc(t: ^testing.T) {
	cases := []Unsupported_Case {
		{data = "\xff\xfeA\x00\r\x00\n\x00", encoding = .UTF16_LE, bom = .UTF16_LE},
		{data = "\xfe\xff\x00A\x00\r\x00\n", encoding = .UTF16_BE, bom = .UTF16_BE},
		{data = "\xff\xfe\x00\x00A\x00\x00\x00", encoding = .UTF32_LE, bom = .UTF32_LE},
		{data = "\x00\x00\xfe\xff\x00\x00\x00A", encoding = .UTF32_BE, bom = .UTF32_BE},
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
			testing.expect(t, decoded.metadata.encoding == c.encoding)
			testing.expect(t, decoded.metadata.bom == c.bom)
			testing.expect(t, decoded.metadata.newline == .Unknown)
			testing.expect(t, decoded.content.length == 0)
			expect_stream(t, decoded.raw, transmute([]byte)data)
			expect_stream(t, decoded.content, {})
		}
	}
}

@(test)
test_utf8_scalar_boundaries_match_rope_counting :: proc(t: ^testing.T) {
	cases := []string {
		"\x00\x7f",
		"\xc2\x80",
		"\xdf\xbf",
		"\xe0\xa0\x80",
		"\xed\x9f\xbf",
		"\xee\x80\x80",
		"\xef\xbf\xbf",
		"\xf0\x90\x80\x80",
		"\xf4\x8f\xbf\xbf",
	}
	for data in cases {
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, transmute([]byte)data, 1)
		defer fileload.loaded_destroy(&loaded)

		decoded := filecodec.decode_loaded(&loaded)
		testing.expect(t, decoded.status == .Valid_UTF8)
		testing.expect(t, utf8.valid_string(data))
		metrics := rope.metrics_of(transmute([]byte)data)
		testing.expect(t, metrics.scalar_count == utf8.rune_count(data))
		testing.expect(t, metrics.scalar_count == 1 || data == "\x00\x7f")
		expect_stream(t, decoded.content, transmute([]byte)data)
	}
}

@(test)
test_invalid_utf8_is_preserved_and_read_only :: proc(t: ^testing.T) {
	cases := []Invalid_Case {
		{data = "\x80", reason = .Unexpected_Continuation, length = 1},
		{data = "\xbf", reason = .Unexpected_Continuation, length = 1},
		{data = "\xc0\x80", reason = .Overlong, length = 1},
		{data = "\xc1\xbf", reason = .Overlong, length = 1},
		{data = "\xe0\x80\x80", reason = .Overlong, length = 2},
		{data = "\xed\xa0\x80", reason = .Surrogate, length = 2},
		{data = "\xf0\x80\x80\x80", reason = .Overlong, length = 2},
		{data = "\xf4\x90\x80\x80", reason = .Out_Of_Range, length = 2},
		{data = "\xf5\x80\x80\x80", reason = .Out_Of_Range, length = 1},
		{data = "\xff", reason = .Out_Of_Range, length = 1},
		{data = "\xc2A", reason = .Invalid_Continuation, length = 1},
		{data = "\xe1\x80A", reason = .Invalid_Continuation, length = 2},
		{data = "\xc2", reason = .Truncated, length = 1},
		{data = "\xe1\x80", reason = .Truncated, length = 2},
		{data = "\xf1\x80\x80", reason = .Truncated, length = 3},
	}
	for c in cases {
		data := c.data
		for chunk_size in 1 ..= 5 {
			loaded: fileload.Loaded
			loaded_from_bytes(t, &loaded, transmute([]byte)data, chunk_size)
			defer fileload.loaded_destroy(&loaded)

			decoded := filecodec.decode_loaded(&loaded)
			testing.expectf(t, decoded.status == .Invalid_UTF8, "accepted invalid bytes %v", transmute([]byte)data)
			testing.expect(t, !filecodec.can_edit(decoded))
			testing.expect(t, decoded.metadata.encoding == .UTF8)
			testing.expect(t, decoded.invalid.raw_offset == 0)
			testing.expectf(t, decoded.invalid.reason == c.reason, "wrong reason for %v", transmute([]byte)data)
			testing.expect(t, decoded.invalid.length == c.length)
			expect_stream(t, decoded.raw, transmute([]byte)data)
			expect_stream(t, decoded.content, transmute([]byte)data)
		}
	}
}

@(test)
test_invalid_offset_is_raw_and_newlines_still_scan :: proc(t: ^testing.T) {
	data := string("\xef\xbb\xbfok\n\xf0\x90\x80")
	loaded: fileload.Loaded
	loaded_from_bytes(t, &loaded, transmute([]byte)data, 2)
	defer fileload.loaded_destroy(&loaded)

	decoded := filecodec.decode_loaded(&loaded)
	testing.expect(t, decoded.status == .Invalid_UTF8)
	testing.expect(t, decoded.invalid.raw_offset == 6)
	testing.expect(t, decoded.invalid.length == 3)
	testing.expect(t, decoded.invalid.reason == .Truncated)
	testing.expect(t, decoded.metadata.newline == .LF)
	testing.expect(t, decoded.metadata.newlines.lf == 1)
	expect_stream(t, decoded.raw, transmute([]byte)data)
	expect_stream(t, decoded.content, transmute([]byte)string("ok\n\xf0\x90\x80"))
}

@(test)
test_utf8_validity_differential :: proc(t: ^testing.T) {
	for value in 0 ..= 255 {
		data := [1]u8{u8(value)}
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, data[:], 1)
		defer fileload.loaded_destroy(&loaded)
		decoded := filecodec.decode_loaded(&loaded)
		testing.expectf(t, (decoded.status == .Valid_UTF8) == utf8.valid_string(string(data[:])), "single-byte mismatch at %02x", value)
	}

	state := u64(0x4d595df4d0f33173)
	for case_index in 0 ..< 1000 {
		state = xorshift64(state)
		n := int(state % 49)
		data := make([]u8, n, context.allocator)
		for i in 0 ..< n {
			state = xorshift64(state)
			data[i] = u8(state >> 32)
		}
		state = xorshift64(state)
		chunk_size := 1 + int(state%8)
		loaded: fileload.Loaded
		loaded_from_bytes(t, &loaded, data, chunk_size)
		decoded := filecodec.decode_loaded(&loaded)
		if decoded.status != .Unsupported_Encoding {
			want_valid := utf8.valid_string(string(data))
			testing.expectf(
				t,
				(decoded.status == .Valid_UTF8) == want_valid,
				"validity mismatch in case %d, chunk size %d",
				case_index,
				chunk_size,
			)
			expect_stream(t, decoded.raw, data)
		}
		fileload.loaded_destroy(&loaded)
		delete(data)
	}
}

@(test)
test_decode_real_chunked_load :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "hammer-filecodec-*", context.temp_allocator)
	if dir_err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", dir_err)
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/bom-mixed.txt", dir)
	data := string("\xef\xbb\xbfalpha\r\nβ\nomega\r")
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
	testing.expect(t, decoded.status == .Valid_UTF8)
	testing.expect(t, decoded.metadata.bom == .UTF8)
	testing.expect(t, decoded.metadata.newline == .Mixed)
	testing.expect(t, decoded.metadata.newlines.lf == 1)
	testing.expect(t, decoded.metadata.newlines.crlf == 1)
	testing.expect(t, decoded.metadata.newlines.cr == 1)
	expect_stream(t, decoded.raw, transmute([]byte)data)
	expect_stream(t, decoded.content, transmute([]byte)string("alpha\r\nβ\nomega\r"))
}

xorshift64 :: proc(x: u64) -> u64 {
	x := x
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	return x
}
