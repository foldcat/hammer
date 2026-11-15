// Narrow fontconfig 2.18.3 bindings for Linux. Configs and patterns are
// caller-owned unless explicitly referenced; destroy each with its matching
// function. Strings returned by patterns are borrowed until pattern mutation
// or destruction. The process-global default config is referenced, never
// replaced, and FcFini is deliberately not called by the editor.
package fontconfig

import "core:c"

when ODIN_OS != .Linux {
	#panic("hammer fontconfig bindings currently require Linux")
}

foreign import lib "system:fontconfig"

EXPECTED_VERSION :: 21803

Bool :: c.int
Config :: distinct rawptr
Pattern :: distinct rawptr
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
	FcPatternCreate :: proc() -> Pattern ---
	FcPatternDestroy :: proc(pattern: Pattern) ---
	FcPatternAddString :: proc(pattern: Pattern, object: cstring, value: cstring) -> Bool ---
	FcPatternGetString :: proc(pattern: Pattern, object: cstring, n: c.int, value: ^cstring) -> Result ---
	FcPatternGetInteger :: proc(pattern: Pattern, object: cstring, n: c.int, value: ^c.int) -> Result ---
	FcFontMatch :: proc(config: Config, pattern: Pattern, result: ^Result) -> Pattern ---
}
