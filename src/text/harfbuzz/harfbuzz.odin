// Narrow HarfBuzz 12.3.2 bindings for Linux. Destroy buffers, fonts, faces,
// and blobs in reverse creation order. An hb-ft font references its FreeType
// face and must be destroyed first. Glyph result arrays remain owned by their
// buffer and are invalidated by the next buffer mutation or destruction.
package harfbuzz

import "core:c"

import ft "../freetype"

when ODIN_OS != .Linux {
	#panic("hammer HarfBuzz bindings currently require Linux")
}

foreign import lib "system:harfbuzz"

EXPECTED_MAJOR :: 12
EXPECTED_MINOR :: 3
EXPECTED_MICRO :: 2
EXPECTED_VERSION_STRING :: "12.3.2"

Codepoint :: u32
Mask :: u32
Position :: i32
Tag :: u32
Script :: u32
Language :: distinct rawptr
Bool :: c.int

Blob :: struct {}
Face :: struct {}
Font :: struct {}
Buffer :: struct {}

Direction :: enum c.int {
	Invalid = 0,
	LTR     = 4,
	RTL     = 5,
	TTB     = 6,
	BTT     = 7,
}

Var_Int :: struct #raw_union {
	u32: u32,
	i32: i32,
	u16: [2]u16,
	i16: [2]i16,
	u8:  [4]u8,
	i8:  [4]i8,
}

Glyph_Info :: struct {
	codepoint: Codepoint,
	mask:      Mask,
	cluster:   u32,
	var1:      Var_Int,
	var2:      Var_Int,
}

Glyph_Position :: struct {
	x_advance: Position,
	y_advance: Position,
	x_offset:  Position,
	y_offset:  Position,
	var:       Var_Int,
}

Segment_Properties :: struct {
	direction: Direction,
	script:    Script,
	language:  Language,
	reserved1: rawptr,
	reserved2: rawptr,
}

Feature :: struct {
	tag:   Tag,
	value: u32,
	start: c.uint,
	end:   c.uint,
}

Variation :: struct {
	tag:   Tag,
	value: f32,
}

#assert(size_of(Glyph_Info) == 20 && offset_of(Glyph_Info, cluster) == 8)
#assert(size_of(Glyph_Position) == 20 && size_of(Segment_Properties) == 32)

@(default_calling_convention = "c")
foreign lib {
	hb_version :: proc(major, minor, micro: ^c.uint) ---
	hb_version_string :: proc() -> cstring ---
	hb_version_atleast :: proc(major, minor, micro: c.uint) -> Bool ---
	hb_blob_create_from_file_or_fail :: proc(file_name: cstring) -> ^Blob ---
	hb_blob_destroy :: proc(blob: ^Blob) ---
	hb_face_create :: proc(blob: ^Blob, index: c.uint) -> ^Face ---
	hb_face_destroy :: proc(face: ^Face) ---
	hb_font_create :: proc(face: ^Face) -> ^Font ---
	hb_font_get_empty :: proc() -> ^Font ---
	hb_font_destroy :: proc(font: ^Font) ---
	hb_font_set_scale :: proc(font: ^Font, x_scale, y_scale: c.int) ---
	hb_font_set_ppem :: proc(font: ^Font, x_ppem, y_ppem: c.uint) ---
	hb_ft_font_create_referenced :: proc(ft_face: ft.Face) -> ^Font ---
	hb_ft_font_changed :: proc(font: ^Font) ---
	hb_ft_font_set_load_flags :: proc(font: ^Font, load_flags: c.int) ---
	hb_buffer_create :: proc() -> ^Buffer ---
	hb_buffer_destroy :: proc(buffer: ^Buffer) ---
	hb_buffer_add_utf8 :: proc(buffer: ^Buffer, text: [^]u8, text_length: c.int, item_offset: c.uint, item_length: c.int) ---
	hb_buffer_add_utf16 :: proc(buffer: ^Buffer, text: [^]u16, text_length: c.int, item_offset: c.uint, item_length: c.int) ---
	hb_buffer_guess_segment_properties :: proc(buffer: ^Buffer) ---
	hb_buffer_get_segment_properties :: proc(buffer: ^Buffer, props: ^Segment_Properties) ---
	hb_buffer_set_direction :: proc(buffer: ^Buffer, direction: Direction) ---
	hb_buffer_get_length :: proc(buffer: ^Buffer) -> c.uint ---
	hb_buffer_get_glyph_infos :: proc(buffer: ^Buffer, length: ^c.uint) -> [^]Glyph_Info ---
	hb_buffer_get_glyph_positions :: proc(buffer: ^Buffer, length: ^c.uint) -> [^]Glyph_Position ---
	hb_shape :: proc(font: ^Font, buffer: ^Buffer, features: [^]Feature, num_features: c.uint) ---
	hb_feature_from_string :: proc(str: cstring, len: c.int, feature: ^Feature) -> Bool ---
	hb_tag_from_string :: proc(str: cstring, len: c.int) -> Tag ---
	hb_language_from_string :: proc(str: cstring, len: c.int) -> Language ---
}
