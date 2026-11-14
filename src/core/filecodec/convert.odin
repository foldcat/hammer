package filecodec

import "base:runtime"
import "core:unicode/utf8"

// Conversion_Request makes a potentially destructive encoding change an
// explicit caller decision. Lossy conversion is rejected unless allow_lossy
// is true; conversion never mutates the source Decoded or Loaded.
Conversion_Request :: struct {
	allow_lossy: bool,
}

// Conversion_Error distinguishes deliberate-loss refusal from resource
// exhaustion. A successful result is always valid UTF-8 without a BOM.
Conversion_Error :: enum {
	None,
	Lossy_Confirmation_Required,
	Resource_Limit,
}

// Conversion owns converted UTF-8 text. `replacements` counts malformed source
// units replaced by U+FFFD; a nonzero count means the conversion was lossy.
Conversion :: struct {
	text:         []byte,
	lossy:        bool,
	replacements: int,
	allocator:    runtime.Allocator,
}

// convert_to_utf8 deliberately creates a new editable UTF-8 representation.
// Valid UTF-8 content is copied byte-for-byte. Invalid UTF-8 and malformed
// UTF-16/32 require allow_lossy and replace each malformed unit with U+FFFD.
// Well-formed UTF-16/32 conversion is lossless apart from removing its BOM.
convert_to_utf8 :: proc(
	decoded: Decoded,
	request: Conversion_Request,
	allocator := context.allocator,
) -> (Conversion, Conversion_Error) {
	if decoded.status == .Valid_UTF8 {
		text, err := make([]byte, decoded.content.length, allocator)
		if err != .None {
			return {}, .Resource_Limit
		}
		it := stream_iter_init(decoded.content)
		pos := 0
		for {
			span, ok := stream_iter_next(&it)
			if !ok {
				break
			}
			copy(text[pos:], span)
			pos += len(span)
		}
		return Conversion{text = text, allocator = allocator}, .None
	}

	text_len, replacements, ok := conversion_walk(decoded, nil)
	if !ok {
		return {}, .Resource_Limit
	}
	if replacements > 0 && !request.allow_lossy {
		return {}, .Lossy_Confirmation_Required
	}
	text, err := make([]byte, text_len, allocator)
	if err != .None {
		return {}, .Resource_Limit
	}
	written, written_replacements, filled := conversion_walk(decoded, text)
	if !filled || written != text_len || written_replacements != replacements {
		delete(text, allocator)
		return {}, .Resource_Limit
	}
	return Conversion {
		text = text,
		lossy = replacements > 0,
		replacements = replacements,
		allocator = allocator,
	}, .None
}

// conversion_destroy releases converted text and resets the result.
conversion_destroy :: proc(conversion: ^Conversion) {
	if conversion.allocator.procedure != nil {
		delete(conversion.text, conversion.allocator)
	}
	conversion^ = Conversion{}
}

conversion_walk :: proc(decoded: Decoded, out: []byte) -> (int, int, bool) {
	if decoded.status == .Invalid_UTF8 {
		return replace_invalid_utf8(decoded.content, out)
	}
	if decoded.status == .Unsupported_Encoding {
		stream := decoded.raw
		bom_len := 0
		switch decoded.metadata.bom {
		case .None, .UTF8:
		case .UTF16_LE, .UTF16_BE:
			bom_len = 2
		case .UTF32_LE, .UTF32_BE:
			bom_len = 4
		}
		stream.raw_start += bom_len
		stream.length -= bom_len
		return decode_wide_utf8(stream, decoded.metadata.encoding, out)
	}
	return 0, 0, false
}

replace_invalid_utf8 :: proc(stream: Byte_Stream, out: []byte) -> (int, int, bool) {
	cursor := byte_cursor{it = stream_iter_init(stream)}
	pos := 0
	replacements := 0
	for {
		token: [4]byte
		n := cursor_peek(cursor, token[:])
		if n == 0 {
			break
		}
		r, width := utf8.decode_rune(token[:n])
		valid := r != utf8.RUNE_ERROR || width != 1
		if !valid {
			width = 1
		}
		for _ in 0 ..< width {
			cursor_next(&cursor)
		}
		if valid {
			if !conversion_write(out, &pos, token[:width]) {
				return 0, 0, false
			}
		} else {
			encoded, encoded_len := utf8.encode_rune(utf8.RUNE_ERROR)
			if !conversion_write(out, &pos, encoded[:encoded_len]) {
				return 0, 0, false
			}
			replacements += 1
		}
	}
	return pos, replacements, true
}

decode_wide_utf8 :: proc(stream: Byte_Stream, encoding: Encoding, out: []byte) -> (int, int, bool) {
	unit_size := 2
	little_endian := encoding == .UTF16_LE
	if encoding == .UTF32_LE || encoding == .UTF32_BE {
		unit_size = 4
		little_endian = encoding == .UTF32_LE
	}
	cursor := byte_cursor{it = stream_iter_init(stream)}
	pos := 0
	replacements := 0
	for {
		first, width := next_unit(&cursor, unit_size, little_endian)
		if width == 0 {
			break
		}
		r := utf8.RUNE_ERROR
		lossy := true
		if width == unit_size {
			if unit_size == 2 {
				switch {
				case first >= 0xd800 && first <= 0xdbff:
					saved := cursor
					second, second_width := next_unit(&cursor, 2, little_endian)
					if second_width == 2 && second >= 0xdc00 && second <= 0xdfff {
						r = rune(0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00))
						lossy = false
					} else {
						cursor = saved
					}
				case first >= 0xdc00 && first <= 0xdfff:
				case:
					r = rune(first)
					lossy = false
				}
			} else if first <= 0x10ffff && (first < 0xd800 || first > 0xdfff) {
				r = rune(first)
				lossy = false
			}
		}
		if lossy {
			replacements += 1
		}
		encoded, encoded_len := utf8.encode_rune(r)
		if !conversion_write(out, &pos, encoded[:encoded_len]) {
			return 0, 0, false
		}
	}
	return pos, replacements, true
}

next_unit :: proc(cursor: ^byte_cursor, size: int, little_endian: bool) -> (u32, int) {
	bytes: [4]byte
	n := cursor_peek(cursor^, bytes[:size])
	for _ in 0 ..< n {
		cursor_next(cursor)
	}
	if n < size {
		return 0, n
	}
	value := u32(0)
	if little_endian {
		for i := size - 1; i >= 0; i -= 1 {
			value = value << 8 | u32(bytes[i])
		}
	} else {
		for i in 0 ..< size {
			value = value << 8 | u32(bytes[i])
		}
	}
	return value, n
}

conversion_write :: proc(out: []byte, pos: ^int, bytes: []byte) -> bool {
	max_int := int(~uint(0) >> 1)
	if pos^ > max_int - len(bytes) {
		return false
	}
	if len(out) > 0 {
		copy(out[pos^:], bytes)
	}
	pos^ += len(bytes)
	return true
}
