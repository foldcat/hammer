// Narrow FreeType 2.15.0 bindings for Linux/x86_64. A Library owns its
// faces; destroy faces before the library. Memory-face bytes are borrowed
// until FT_Done_Face returns. Public records match the pinned C headers.
package freetype

import "core:c"

when ODIN_OS != .Linux {
	#panic("hammer FreeType bindings currently require Linux")
}

foreign import lib "system:freetype"

EXPECTED_MAJOR :: 2
EXPECTED_MINOR :: 15
EXPECTED_PATCH :: 0
PKG_CONFIG_VERSION :: "26.7.20"

Error :: c.int
Long :: c.long
ULong :: c.ulong
Pos :: c.long
Fixed :: c.long

Library_Rec :: struct {}
Library :: ^Library_Rec
Face :: ^Face_Rec
Glyph_Slot :: ^Glyph_Slot_Rec
Size :: ^Size_Rec

Generic_Finalizer :: proc "c" (object: rawptr)
Generic :: struct {
	data:      rawptr,
	finalizer: Generic_Finalizer,
}

Vector :: struct {
	x, y: Pos,
}

BBox :: struct {
	x_min, y_min: Pos,
	x_max, y_max: Pos,
}

Bitmap_Size :: struct {
	height, width: c.short,
	size:          Pos,
	x_ppem:        Pos,
	y_ppem:        Pos,
}

Bitmap :: struct {
	rows:         c.uint,
	width:        c.uint,
	pitch:        c.int,
	buffer:       [^]u8,
	num_grays:    c.ushort,
	pixel_mode:   u8,
	palette_mode: u8,
	palette:      rawptr,
}

Glyph_Metrics :: struct {
	width:         Pos,
	height:        Pos,
	hori_bearing_x: Pos,
	hori_bearing_y: Pos,
	hori_advance:  Pos,
	vert_bearing_x: Pos,
	vert_bearing_y: Pos,
	vert_advance:  Pos,
}

Outline :: struct {
	n_contours: c.ushort,
	n_points:   c.ushort,
	points:     [^]Vector,
	tags:       [^]u8,
	contours:   [^]c.ushort,
	flags:      c.int,
}

List_Rec :: struct {
	head: rawptr,
	tail: rawptr,
}

Face_Rec :: struct {
	num_faces:           Long,
	face_index:          Long,
	face_flags:          Long,
	style_flags:         Long,
	num_glyphs:          Long,
	family_name:         cstring,
	style_name:          cstring,
	num_fixed_sizes:     c.int,
	available_sizes:     [^]Bitmap_Size,
	num_charmaps:        c.int,
	charmaps:            rawptr,
	generic:             Generic,
	bbox:                BBox,
	units_per_em:        c.ushort,
	ascender:            c.short,
	descender:           c.short,
	height:              c.short,
	max_advance_width:   c.short,
	max_advance_height:  c.short,
	underline_position:  c.short,
	underline_thickness: c.short,
	glyph:               Glyph_Slot,
	size:                Size,
	charmap:             rawptr,
	driver:              rawptr,
	memory:              rawptr,
	stream:              rawptr,
	sizes_list:          List_Rec,
	autohint:            Generic,
	extensions:          rawptr,
	internal:            rawptr,
}

Size_Metrics :: struct {
	x_ppem:      c.ushort,
	y_ppem:      c.ushort,
	x_scale:     Fixed,
	y_scale:     Fixed,
	ascender:    Pos,
	descender:   Pos,
	height:      Pos,
	max_advance: Pos,
}

Size_Rec :: struct {
	face:     Face,
	generic:  Generic,
	metrics:  Size_Metrics,
	internal: rawptr,
}

Glyph_Slot_Rec :: struct {
	library:             Library,
	face:                Face,
	next:                Glyph_Slot,
	glyph_index:         c.uint,
	generic:             Generic,
	metrics:             Glyph_Metrics,
	linear_hori_advance: Fixed,
	linear_vert_advance: Fixed,
	advance:             Vector,
	format:              u32,
	bitmap:              Bitmap,
	bitmap_left:         c.int,
	bitmap_top:          c.int,
	outline:             Outline,
	num_subglyphs:       c.uint,
	subglyphs:           rawptr,
	control_data:        rawptr,
	control_len:         c.long,
	lsb_delta:           Pos,
	rsb_delta:           Pos,
	other:               rawptr,
	internal:            rawptr,
}

Load_Flags :: c.int
LOAD_DEFAULT :: Load_Flags(0)
LOAD_RENDER :: Load_Flags(1 << 2)

Render_Mode :: enum c.int {
	Normal = 0,
	Mono   = 1,
	LCD    = 2,
	LCD_V  = 3,
	BGRA   = 4,
}

Pixel_Mode :: enum u8 {
	None   = 0,
	Mono   = 1,
	Gray   = 2,
	Gray2  = 3,
	Gray4  = 4,
	LCD    = 5,
	LCD_V  = 6,
	BGRA   = 7,
}

#assert(size_of(Face_Rec) == 248 && offset_of(Face_Rec, glyph) == 152 && offset_of(Face_Rec, size) == 160)
#assert(size_of(Glyph_Slot_Rec) == 304 && offset_of(Glyph_Slot_Rec, bitmap) == 152 && offset_of(Glyph_Slot_Rec, outline) == 200)
#assert(size_of(Size_Rec) == 88 && offset_of(Size_Rec, metrics) == 24)
#assert(size_of(Bitmap) == 40 && size_of(Outline) == 40)

@(default_calling_convention = "c")
foreign lib {
	FT_Init_FreeType :: proc(alibrary: ^Library) -> Error ---
	FT_Done_FreeType :: proc(library: Library) -> Error ---
	FT_Library_Version :: proc(library: Library, major, minor, patch: ^c.int) ---
	FT_New_Face :: proc(library: Library, filepathname: cstring, face_index: Long, aface: ^Face) -> Error ---
	FT_New_Memory_Face :: proc(library: Library, file_base: [^]u8, file_size, face_index: Long, aface: ^Face) -> Error ---
	FT_Done_Face :: proc(face: Face) -> Error ---
	FT_Set_Pixel_Sizes :: proc(face: Face, pixel_width, pixel_height: c.uint) -> Error ---
	FT_Get_Char_Index :: proc(face: Face, charcode: ULong) -> c.uint ---
	FT_Load_Char :: proc(face: Face, charcode: ULong, load_flags: Load_Flags) -> Error ---
	FT_Load_Glyph :: proc(face: Face, glyph_index: c.uint, load_flags: Load_Flags) -> Error ---
	FT_Render_Glyph :: proc(slot: Glyph_Slot, render_mode: Render_Mode) -> Error ---
}
