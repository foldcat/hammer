package filecodec

import "base:runtime"
import "core:mem"
import "core:unicode/utf8"

// Display_Kind describes how one source range was projected for display.
Display_Kind :: enum {
	Literal,
	Escaped,
}

// Offset_Map maps a contiguous raw-byte range to a contiguous display range.
// Literal ranges have equal lengths. Escaped ranges use four display bytes
// (`\xNN`) for each raw byte. Offsets are relative to the complete raw file.
Offset_Map :: struct {
	raw_start:     int,
	raw_length:    int,
	display_start: int,
	display_length: int,
	kind:          Display_Kind,
}

// Display owns valid UTF-8 display text and its raw/display offset map.
// Invalid UTF-8 bytes are rendered as `\xNN`; unsupported encodings render
// every raw byte that way. A UTF-8 BOM remains metadata and is not displayed.
// Display never borrows the Decoded or its Loaded after construction.
Display :: struct {
	text:       []byte,
	offsets:    []Offset_Map,
	raw_start:  int,
	raw_length: int,
	allocator:  runtime.Allocator,
}

// Parser_Mode is the safe syntax-input policy for a decoded file. Invalid
// UTF-8 degrades to plain text; unsupported encodings disable parsing.
Parser_Mode :: enum {
	UTF8,
	Plain_Text,
	Disabled,
}

byte_cursor :: struct {
	it:    Span_Iter,
	span:  []byte,
	index: int,
}

cursor_next :: proc(cursor: ^byte_cursor) -> (byte, bool) {
	for cursor.index >= len(cursor.span) {
		span, ok := stream_iter_next(&cursor.it)
		if !ok {
			return 0, false
		}
		cursor.span = span
		cursor.index = 0
	}
	b := cursor.span[cursor.index]
	cursor.index += 1
	return b, true
}

cursor_peek :: proc(cursor: byte_cursor, dest: []byte) -> int {
	cursor := cursor
	n := 0
	for n < len(dest) {
		b, ok := cursor_next(&cursor)
		if !ok {
			break
		}
		dest[n] = b
		n += 1
	}
	return n
}

// parser_mode returns the only parser input mode safe for decoded.status.
parser_mode :: proc(decoded: Decoded) -> Parser_Mode {
	switch decoded.status {
	case .Valid_UTF8:
		return .UTF8
	case .Invalid_UTF8:
		return .Plain_Text
	case .Unsupported_Encoding:
		return .Disabled
	}
	return .Disabled
}

// display_make constructs an owned, byte-preserving display projection. The
// original Loaded remains untouched. On failure no allocation is retained.
display_make :: proc(
	decoded: Decoded,
	allocator := context.allocator,
) -> (Display, mem.Allocator_Error) {
	text_len, map_count, ok := display_walk(decoded, nil, nil)
	if !ok {
		return {}, .Out_Of_Memory
	}
	text, text_err := make([]byte, text_len, allocator)
	if text_err != .None {
		return {}, text_err
	}
	offsets, map_err := make([]Offset_Map, map_count, allocator)
	if map_err != .None {
		delete(text, allocator)
		return {}, map_err
	}
	written_text, written_maps, filled := display_walk(decoded, text, offsets)
	if !filled || written_text != text_len || written_maps != map_count {
		delete(text, allocator)
		delete(offsets, allocator)
		return {}, .Out_Of_Memory
	}
	stream := decoded.content
	if decoded.status == .Unsupported_Encoding {
		stream = decoded.raw
	}
	return Display {
		text = text,
		offsets = offsets,
		raw_start = stream.raw_start,
		raw_length = stream.length,
		allocator = allocator,
	}, .None
}

// display_destroy releases the projection's allocations and resets it.
display_destroy :: proc(display: ^Display) {
	if display.allocator.procedure != nil {
		delete(display.text, display.allocator)
		delete(display.offsets, display.allocator)
	}
	display^ = Display{}
}

// raw_to_display maps a raw-file position to a display position. Positions at
// either end of a mapped range are accepted. Bytes hidden as metadata, such as
// a UTF-8 BOM, have no display position.
raw_to_display :: proc(display: Display, raw_offset: int) -> (int, bool) {
	if raw_offset < display.raw_start || raw_offset > display.raw_start + display.raw_length {
		return 0, false
	}
	if display.raw_length == 0 {
		return 0, true
	}
	for mapping in display.offsets {
		raw_end := mapping.raw_start + mapping.raw_length
		if raw_offset < mapping.raw_start || raw_offset > raw_end {
			continue
		}
		delta := raw_offset - mapping.raw_start
		if mapping.kind == .Escaped {
			return mapping.display_start + delta * 4, true
		}
		return mapping.display_start + delta, true
	}
	return 0, false
}

// display_to_raw maps a display position to a raw-file position. A position
// inside an escape sequence is not a raw-byte boundary and returns ok=false.
display_to_raw :: proc(display: Display, display_offset: int) -> (int, bool) {
	if display_offset < 0 || display_offset > len(display.text) {
		return 0, false
	}
	if display.raw_length == 0 {
		return display.raw_start, display_offset == 0
	}
	for mapping in display.offsets {
		display_end := mapping.display_start + mapping.display_length
		if display_offset < mapping.display_start || display_offset > display_end {
			continue
		}
		delta := display_offset - mapping.display_start
		if mapping.kind == .Escaped {
			if delta % 4 != 0 {
				return 0, false
			}
			return mapping.raw_start + delta / 4, true
		}
		return mapping.raw_start + delta, true
	}
	return 0, false
}

display_walk :: proc(decoded: Decoded, text: []byte, offsets: []Offset_Map) -> (int, int, bool) {
	stream := decoded.content
	escape_all := decoded.status == .Unsupported_Encoding
	if escape_all {
		stream = decoded.raw
	}
	cursor := byte_cursor{it = stream_iter_init(stream)}
	raw_pos := stream.raw_start
	display_pos := 0
	map_count := 0
	mapping: Offset_Map
	mapping_active := false
	max_int := int(~uint(0) >> 1)

	for {
		token: [4]byte
		width := 0
		valid := false
		if escape_all {
			b, next_ok := cursor_next(&cursor)
			if !next_ok {
				break
			}
			token[0] = b
			width = 1
		} else {
			n := cursor_peek(cursor, token[:])
			if n == 0 {
				break
			}
			r, decoded_width := utf8.decode_rune(token[:n])
			valid = r != utf8.RUNE_ERROR || decoded_width != 1
			width = decoded_width
			if !valid {
				width = 1
			}
			for _ in 0 ..< width {
				cursor_next(&cursor)
			}
		}

		kind := Display_Kind.Escaped
		token_display_len := 4
		if valid {
			kind = .Literal
			token_display_len = width
		}
		if display_pos > max_int - token_display_len {
			return 0, 0, false
		}
		if mapping_active && mapping.kind != kind {
			display_flush(&mapping, &mapping_active, offsets, &map_count)
		}
		if !mapping_active {
			mapping = Offset_Map {
				raw_start = raw_pos,
				display_start = display_pos,
				kind = kind,
			}
			mapping_active = true
		}
		if len(text) > 0 {
			if valid {
				copy(text[display_pos:], token[:width])
			} else {
				write_escaped_byte(text[display_pos:], token[0])
			}
		}
		raw_pos += width
		display_pos += token_display_len
		mapping.raw_length += width
		mapping.display_length += token_display_len
	}
	display_flush(&mapping, &mapping_active, offsets, &map_count)
	return display_pos, map_count, true
}

display_flush :: proc(
	mapping: ^Offset_Map,
	active: ^bool,
	offsets: []Offset_Map,
	count: ^int,
) {
	if !active^ {
		return
	}
	if len(offsets) > 0 {
		offsets[count^] = mapping^
	}
	count^ += 1
	active^ = false
}

write_escaped_byte :: proc(dest: []byte, b: byte) {
	hex := string("0123456789abcdef")
	dest[0] = '\\'
	dest[1] = 'x'
	dest[2] = hex[b >> 4]
	dest[3] = hex[b & 0x0f]
}
