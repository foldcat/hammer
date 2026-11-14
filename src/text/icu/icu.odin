// ICU4C 78.3 common-library bindings for Linux. This pin uses an ICU build
// with symbol renaming disabled (unadorned C symbols). Break iterators and
// bidi objects are caller-owned and closed with their matching close call;
// input UTF-16 and output maps are borrowed only for the documented call or
// object lifetime. No ICU allocation is released through an Odin allocator.
package icu

import "core:c"

when ODIN_OS != .Linux {
	#panic("hammer ICU bindings currently require Linux")
}

foreign import lib "system:icuuc"

EXPECTED_MAJOR :: 78
EXPECTED_MINOR :: 3
EXPECTED_PATCH :: 0
EXPECTED_UNICODE_MAJOR :: 17
EXPECTED_UNICODE_MINOR :: 0

Version_Info :: [4]u8
UChar :: u16
Char32 :: i32
Bool :: i8
Error_Code :: c.int
ZERO_ERROR :: Error_Code(0)
DONE :: i32(-1)

success :: proc(code: Error_Code) -> bool {
	return code <= ZERO_ERROR
}

failure :: proc(code: Error_Code) -> bool {
	return code > ZERO_ERROR
}

Break_Iterator :: distinct rawptr
Break_Iterator_Type :: enum c.int {
	Character = 0,
	Word      = 1,
	Line      = 2,
	Sentence  = 3,
}

Bidi :: distinct rawptr
Bidi_Level :: u8
DEFAULT_LTR :: Bidi_Level(0xfe)
DEFAULT_RTL :: Bidi_Level(0xff)
MAP_NOWHERE :: i32(-1)

Bidi_Direction :: enum c.int {
	LTR     = 0,
	RTL     = 1,
	Mixed   = 2,
	Neutral = 3,
}

Property :: c.int
ALPHABETIC :: Property(0)
BIDI_CONTROL :: Property(2)
NONCHARACTER_CODE_POINT :: Property(24)
WHITE_SPACE :: Property(31)

Char_Category :: enum c.int {
	Unassigned             = 0,
	Uppercase_Letter       = 1,
	Lowercase_Letter       = 2,
	Titlecase_Letter       = 3,
	Modifier_Letter        = 4,
	Other_Letter           = 5,
	Non_Spacing_Mark       = 6,
	Enclosing_Mark         = 7,
	Combining_Spacing_Mark = 8,
	Decimal_Digit_Number   = 9,
	Letter_Number          = 10,
	Other_Number           = 11,
	Space_Separator        = 12,
	Line_Separator         = 13,
	Paragraph_Separator    = 14,
	Control_Char           = 15,
	Format_Char            = 16,
	Private_Use_Char       = 17,
	Surrogate              = 18,
	Dash_Punctuation       = 19,
	Start_Punctuation      = 20,
	End_Punctuation        = 21,
	Connector_Punctuation  = 22,
	Other_Punctuation      = 23,
	Math_Symbol            = 24,
	Currency_Symbol        = 25,
	Modifier_Symbol        = 26,
	Other_Symbol           = 27,
	Initial_Punctuation    = 28,
	Final_Punctuation      = 29,
}

@(default_calling_convention = "c")
foreign lib {
	u_getVersion :: proc(version_array: ^Version_Info) ---
	u_getUnicodeVersion :: proc(version_array: ^Version_Info) ---
	u_charType :: proc(c: Char32) -> Char_Category ---
	u_hasBinaryProperty :: proc(c: Char32, which: Property) -> Bool ---
	ubrk_open :: proc(type: Break_Iterator_Type, locale: cstring, text: [^]UChar, text_length: i32, status: ^Error_Code) -> Break_Iterator ---
	ubrk_setText :: proc(bi: Break_Iterator, text: [^]UChar, text_length: i32, status: ^Error_Code) ---
	ubrk_first :: proc(bi: Break_Iterator) -> i32 ---
	ubrk_next :: proc(bi: Break_Iterator) -> i32 ---
	ubrk_close :: proc(bi: Break_Iterator) ---
	ubidi_open :: proc() -> Bidi ---
	ubidi_close :: proc(bidi: Bidi) ---
	ubidi_setPara :: proc(bidi: Bidi, text: [^]UChar, length: i32, para_level: Bidi_Level, embedding_levels: [^]Bidi_Level, status: ^Error_Code) ---
	ubidi_getDirection :: proc(bidi: Bidi) -> Bidi_Direction ---
	ubidi_getParaLevel :: proc(bidi: Bidi) -> Bidi_Level ---
	ubidi_countRuns :: proc(bidi: Bidi, status: ^Error_Code) -> i32 ---
	ubidi_getLogicalMap :: proc(bidi: Bidi, index_map: [^]i32, status: ^Error_Code) ---
	ubidi_getVisualMap :: proc(bidi: Bidi, index_map: [^]i32, status: ^Error_Code) ---
	ubidi_getLogicalIndex :: proc(bidi: Bidi, visual_index: i32, status: ^Error_Code) -> i32 ---
	ubidi_getVisualIndex :: proc(bidi: Bidi, logical_index: i32, status: ^Error_Code) -> i32 ---
}
