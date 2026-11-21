// Narrow fontconfig 2.18.3 bindings for Linux. Configs, charsets, and patterns
// are caller-owned unless explicitly referenced; destroy each with its matching
// function. Strings returned by patterns are borrowed until pattern mutation
// or destruction. The process-global default config is referenced, never
// replaced, and FcFini is deliberately not called by the editor.
package fontconfig

import "core:c"

when ODIN_OS != .Linux {
	#panic("hammer fontconfig bindings currently require Linux")
}

// STATIC_TEXT is defined by make.odin for release builds that stage the full
// static text stack (see make.odin static_text_flags). The archive is a stable
// relative path from this package directory to the generated build tree.
STATIC_TEXT :: #config(HAMMER_STATIC_TEXT, false)
when STATIC_TEXT {
	foreign import lib { "../../../build/static/libfontconfig.a" }
} else {
	foreign import lib "system:fontconfig"
}

EXPECTED_VERSION :: 21803

Bool :: c.int
Config :: distinct rawptr
Pattern :: distinct rawptr
CharSet :: distinct rawptr
Char32 :: u32
Match_Kind :: enum c.int {
	Pattern = 0,
	Font    = 1,
	Scan    = 2,
}
Result :: enum c.int {
	Match          = 0,
	No_Match       = 1,
	Type_Mismatch  = 2,
	No_Id          = 3,
	Out_Of_Memory  = 4,
}

FAMILY :: "family"
FILE :: "file"
INDEX :: "index"
CHARSET :: "charset"

@(default_calling_convention = "c")
foreign lib {
	FcGetVersion :: proc() -> c.int ---
	FcInit :: proc() -> Bool ---
	FcConfigCreate :: proc() -> Config ---
	FcConfigReference :: proc(config: Config) -> Config ---
	FcConfigGetCurrent :: proc() -> Config ---
	FcConfigDestroy :: proc(config: Config) ---
	FcConfigBuildFonts :: proc(config: Config) -> Bool ---
	FcConfigParseAndLoad :: proc(config: Config, file: cstring, complain: Bool) -> Bool ---
	FcConfigSubstitute :: proc(config: Config, pattern: Pattern, kind: Match_Kind) -> Bool ---
	FcDefaultSubstitute :: proc(pattern: Pattern) ---
	FcCharSetCreate :: proc() -> CharSet ---
	FcCharSetDestroy :: proc(charset: CharSet) ---
	FcCharSetAddChar :: proc(charset: CharSet, codepoint: Char32) -> Bool ---
	FcPatternCreate :: proc() -> Pattern ---
	FcPatternDestroy :: proc(pattern: Pattern) ---
	FcPatternAddString :: proc(pattern: Pattern, object: cstring, value: cstring) -> Bool ---
	FcPatternAddCharSet :: proc(pattern: Pattern, object: cstring, charset: CharSet) -> Bool ---
	FcPatternGetString :: proc(pattern: Pattern, object: cstring, n: c.int, value: ^cstring) -> Result ---
	FcPatternGetInteger :: proc(pattern: Pattern, object: cstring, n: c.int, value: ^c.int) -> Result ---
	FcFontMatch :: proc(config: Config, pattern: Pattern, result: ^Result) -> Pattern ---
}
