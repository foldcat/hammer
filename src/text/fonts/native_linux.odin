package fonts

import "core:strings"

import errs "../../core/errs"
import ft "../freetype"
import fc "../fontconfig"

MAX_PATH_BYTES :: 4096
MAX_FAMILIES :: 4
MAX_FAMILY_BYTES :: 64

Impl :: struct {
	library: ft.Library,
	config:  fc.Config,
}

Location :: struct {
	path:       string,
	family:     string,
	face_index: int,
}

init :: proc(set: ^Set, options: Options, allocator := context.allocator) -> errs.Error {
	set^ = Set{allocator = allocator}
	if fc.FcGetVersion() != fc.EXPECTED_VERSION {
		return errs.newf(.Unsupported, "fontconfig version mismatch: got %d, want %d", fc.FcGetVersion(), fc.EXPECTED_VERSION, allocator = allocator)
	}
	if err := validate_options(options, allocator); !errs.ok(err) {
		return err
	}

	if options.config_path == "" {
		if fc.FcInit() == 0 {
			return errs.new(.IO, "fontconfig initialization failed", allocator = allocator)
		}
		current := fc.FcConfigGetCurrent()
		if current == nil {
			return errs.new(.IO, "fontconfig has no current configuration", allocator = allocator)
		}
		set.impl.config = fc.FcConfigReference(current)
		if set.impl.config == nil {
			return errs.new(.IO, "fontconfig could not reference the current configuration", allocator = allocator)
		}
	} else {
		set.impl.config = fc.FcConfigCreate()
		if set.impl.config == nil {
			return errs.new(.IO, "fontconfig could not create an isolated configuration", allocator = allocator)
		}
		config_path, alloc_err := strings.clone_to_cstring(options.config_path, allocator)
		if alloc_err != nil {
			destroy(set)
			return errs.new(.Resource_Limit, "cannot allocate the fontconfig path", allocator = allocator)
		}
		parsed := fc.FcConfigParseAndLoad(set.impl.config, config_path, 1)
		delete(config_path, allocator)
		if parsed == 0 {
			destroy(set)
			return errs.newf(.IO, "cannot load fontconfig file %s", options.config_path, allocator = allocator)
		}
		if fc.FcConfigBuildFonts(set.impl.config) == 0 {
			destroy(set)
			return errs.new(.IO, "fontconfig could not build the isolated font set", allocator = allocator)
		}
	}

	if ft.FT_Init_FreeType(&set.impl.library) != 0 {
		destroy(set)
		return errs.new(.Internal, "FreeType initialization failed", allocator = allocator)
	}
	major, minor, patch: i32
	ft.FT_Library_Version(set.impl.library, &major, &minor, &patch)
	if major != ft.EXPECTED_MAJOR || minor != ft.EXPECTED_MINOR || patch != ft.EXPECTED_PATCH {
		destroy(set)
		return errs.newf(.Unsupported, "FreeType version mismatch: got %d.%d.%d", major, minor, patch, allocator = allocator)
	}

	for role_index in 0 ..< ROLE_COUNT {
		role := Role(role_index)
		role_options := options.roles[role_index]
		if role == .Emoji && role_options.path == "" && len(role_options.families) == 0 {
			continue
		}
		if role_options.path != "" {
			location := Location{path = role_options.path, face_index = 0}
			if err := load_face(set, role, location); !errs.ok(err) {
				destroy(set)
				return err
			}
			continue
		}

		resolved := false
		for family in role_options.families {
			location, found, discover_err := discover_family(set.impl.config, family, allocator)
			if !errs.ok(discover_err) {
				destroy(set)
				return discover_err
			}
			if !found {
				continue
			}
			load_err := load_face(set, role, location)
			location_destroy(&location, allocator)
			if !errs.ok(load_err) {
				destroy(set)
				return load_err
			}
			resolved = true
			break
		}
		if !resolved && role != .Emoji {
			destroy(set)
			return errs.newf(.NotFound, "no configured font family for the %s role could be loaded", role_name(role), allocator = allocator)
		}
	}
	return errs.Error{}
}

destroy :: proc(set: ^Set) {
	for i in 0 ..< ROLE_COUNT {
		face_destroy(set, &set.faces[i])
	}
	for i in 0 ..< set.fallback_count {
		face_destroy(set, &set.fallbacks[i])
	}
	if set.impl.library != nil {
		ft.FT_Done_FreeType(set.impl.library)
	}
	if set.impl.config != nil {
		fc.FcConfigDestroy(set.impl.config)
	}
	set^ = Set{}
}

validate_options :: proc(options: Options, allocator := context.allocator) -> errs.Error {
	if err := validate_path(options.config_path, "fontconfig path", allocator); !errs.ok(err) {
		return err
	}
	for role_index in 0 ..< ROLE_COUNT {
		role_options := options.roles[role_index]
		role := Role(role_index)
		if err := validate_path(role_options.path, role_name(role), allocator); !errs.ok(err) {
			return err
		}
		if role != .Emoji && role_options.path == "" && len(role_options.families) == 0 {
			return errs.newf(.Invalid_Input, "%s font role has neither a path nor families", role_name(role), allocator = allocator)
		}
		if len(role_options.families) > MAX_FAMILIES {
			return errs.newf(.Resource_Limit, "%s font role has too many families: %d", role_name(role), len(role_options.families), allocator = allocator)
		}
		for family in role_options.families {
			if family == "" || len(family) > MAX_FAMILY_BYTES || strings.contains(family, "\x00") {
				return errs.newf(.Invalid_Input, "%s font role contains an invalid family name", role_name(role), allocator = allocator)
			}
		}
	}
	return errs.Error{}
}

validate_path :: proc(path, what: string, allocator := context.allocator) -> errs.Error {
	if len(path) > MAX_PATH_BYTES || strings.contains(path, "\x00") {
		return errs.newf(.Invalid_Input, "%s is too long or contains NUL", what, allocator = allocator)
	}
	return errs.Error{}
}

discover_family :: proc(config: fc.Config, family: string, allocator := context.allocator) -> (Location, bool, errs.Error) {
	pattern := fc.FcPatternCreate()
	if pattern == nil {
		return {}, false, errs.new(.Resource_Limit, "fontconfig could not allocate a pattern", allocator = allocator)
	}
	defer fc.FcPatternDestroy(pattern)

	family_c, alloc_err := strings.clone_to_cstring(family, allocator)
	if alloc_err != nil {
		return {}, false, errs.new(.Resource_Limit, "cannot allocate a font family query", allocator = allocator)
	}
	defer delete(family_c, allocator)
	if fc.FcPatternAddString(pattern, fc.FAMILY, family_c) == 0 {
		return {}, false, errs.new(.Resource_Limit, "fontconfig could not add the requested family", allocator = allocator)
	}
	if fc.FcConfigSubstitute(config, pattern, .Pattern) == 0 {
		return {}, false, errs.new(.IO, "fontconfig substitution failed", allocator = allocator)
	}
	fc.FcDefaultSubstitute(pattern)

	result: fc.Result
	match := fc.FcFontMatch(config, pattern, &result)
	if result == .Out_Of_Memory {
		return {}, false, errs.new(.Resource_Limit, "fontconfig match allocation failed", allocator = allocator)
	}
	if match == nil || result != .Match {
		return {}, false, errs.Error{}
	}
	defer fc.FcPatternDestroy(match)

	matched_family := ""
	generic := is_generic_family(family)
	for n in 0 ..< 16 {
		value: cstring
		get_result := fc.FcPatternGetString(match, fc.FAMILY, i32(n), &value)
		if get_result != .Match || value == nil {
			break
		}
		actual := string(value)
		if generic || strings.equal_fold(actual, family) {
			matched_family = actual
			break
		}
	}
	if matched_family == "" {
		return {}, false, errs.Error{}
	}

	path_c: cstring
	if fc.FcPatternGetString(match, fc.FILE, 0, &path_c) != .Match || path_c == nil {
		return {}, false, errs.new(.IO, "matched font has no file path", allocator = allocator)
	}
	index: i32
	index_result := fc.FcPatternGetInteger(match, fc.INDEX, 0, &index)
	if (index_result != .Match && index_result != .No_Id) || index < 0 {
		return {}, false, errs.new(.IO, "matched font has an invalid face index", allocator = allocator)
	}
	location := Location{
		path = strings.clone(string(path_c), allocator),
		family = strings.clone(matched_family, allocator),
		face_index = int(index),
	}
	return location, true, errs.Error{}
}

load_face :: proc(set: ^Set, role: Role, location: Location) -> errs.Error {
	loaded, err := open_face(set, role, location, u64(role) + 1)
	if !errs.ok(err) {
		return err
	}
	set.faces[int(role)] = loaded
	return {}
}

open_face :: proc(set: ^Set, role: Role, location: Location, cache_id: u64) -> (Face, errs.Error) {
	path_c, alloc_err := strings.clone_to_cstring(location.path, set.allocator)
	if alloc_err != nil {
		return {}, errs.new(.Resource_Limit, "cannot allocate a font path", allocator = set.allocator)
	}
	defer delete(path_c, set.allocator)

	ft_face: ft.Face
	load_result := ft.FT_New_Face(set.impl.library, path_c, ft.Long(location.face_index), &ft_face)
	if load_result != 0 {
		return {}, errs.newf(.IO, "cannot load %s font %s (FreeType error %d)", role_name(role), location.path, load_result, allocator = set.allocator)
	}
	if ft_face == nil {
		return {}, errs.new(.Internal, "FreeType returned a nil face without an error", allocator = set.allocator)
	}
	family := ""
	if ft_face.family_name != nil {
		family = string(ft_face.family_name)
	}
	return Face{
		role = role,
		cache_id = cache_id,
		path = strings.clone(location.path, set.allocator),
		family = strings.clone(family, set.allocator),
		face_index = location.face_index,
		native = rawptr(ft_face),
	}, {}
}

face_destroy :: proc(set: ^Set, face: ^Face) {
	if face.native != nil && set.impl.library != nil {
		ft.FT_Done_Face(ft.Face(face.native))
	}
	if face.path != "" {
		delete(face.path, set.allocator)
	}
	if face.family != "" {
		delete(face.family, set.allocator)
	}
	face^ = Face{}
}

// Returned faces are owned by set and remain valid until destroy. Unsupported
// codepoints and a full fallback cache return nil without an error.
ensure_fallback :: proc(set: ^Set, codepoint: rune) -> (^Face, errs.Error) {
	if set == nil || set.impl.library == nil || set.impl.config == nil {
		return nil, errs.new(.Invalid_Input, "font fallback requires an initialized font set", allocator = set.allocator if set != nil else context.allocator)
	}
	if codepoint < 0 || codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff {
		return nil, errs.new(.Invalid_Input, "font fallback requires a Unicode scalar value", allocator = set.allocator)
	}
	shaping_roles := [2]Role{.Body, .Emoji}
	for role in shaping_roles {
		face := &set.faces[int(role)]
		if face.native != nil && ft.FT_Get_Char_Index(ft.Face(face.native), ft.ULong(codepoint)) != 0 {
			return face, {}
		}
	}
	for index in 0 ..< set.fallback_count {
		face := &set.fallbacks[index]
		if ft.FT_Get_Char_Index(ft.Face(face.native), ft.ULong(codepoint)) != 0 {
			return face, {}
		}
	}
	for missed in set.misses[:set.miss_count] {
		if missed == codepoint {
			return nil, {}
		}
	}
	if set.fallback_count >= MAX_FALLBACK_FACES {
		record_fallback_miss(set, codepoint)
		return nil, {}
	}

	charset := fc.FcCharSetCreate()
	if charset == nil {
		return nil, errs.new(.Resource_Limit, "fontconfig could not allocate a fallback charset", allocator = set.allocator)
	}
	defer fc.FcCharSetDestroy(charset)
	if fc.FcCharSetAddChar(charset, fc.Char32(codepoint)) == 0 {
		return nil, errs.new(.Resource_Limit, "fontconfig could not populate a fallback charset", allocator = set.allocator)
	}
	pattern := fc.FcPatternCreate()
	if pattern == nil {
		return nil, errs.new(.Resource_Limit, "fontconfig could not allocate a fallback pattern", allocator = set.allocator)
	}
	defer fc.FcPatternDestroy(pattern)
	if fc.FcPatternAddCharSet(pattern, fc.CHARSET, charset) == 0 {
		return nil, errs.new(.Resource_Limit, "fontconfig could not constrain fallback coverage", allocator = set.allocator)
	}
	if fc.FcConfigSubstitute(set.impl.config, pattern, .Pattern) == 0 {
		return nil, errs.new(.IO, "fontconfig fallback substitution failed", allocator = set.allocator)
	}
	fc.FcDefaultSubstitute(pattern)
	result: fc.Result
	match := fc.FcFontMatch(set.impl.config, pattern, &result)
	if result == .Out_Of_Memory {
		return nil, errs.new(.Resource_Limit, "fontconfig fallback match allocation failed", allocator = set.allocator)
	}
	if match == nil || result != .Match {
		record_fallback_miss(set, codepoint)
		return nil, {}
	}
	defer fc.FcPatternDestroy(match)

	path_c: cstring
	if fc.FcPatternGetString(match, fc.FILE, 0, &path_c) != .Match || path_c == nil {
		return nil, errs.new(.IO, "fallback font has no file path", allocator = set.allocator)
	}
	face_index: i32
	index_result := fc.FcPatternGetInteger(match, fc.INDEX, 0, &face_index)
	if (index_result != .Match && index_result != .No_Id) || face_index < 0 {
		return nil, errs.new(.IO, "fallback font has an invalid face index", allocator = set.allocator)
	}
	location := Location{path = strings.clone(string(path_c), set.allocator), face_index = int(face_index)}
	defer location_destroy(&location, set.allocator)

	loaded, load_err := open_face(set, .Body, location, u64(ROLE_COUNT + set.fallback_count + 1))
	if !errs.ok(load_err) {
		return nil, load_err
	}
	if ft.FT_Get_Char_Index(ft.Face(loaded.native), ft.ULong(codepoint)) == 0 {
		face_destroy(set, &loaded)
		record_fallback_miss(set, codepoint)
		return nil, {}
	}
	set.fallbacks[set.fallback_count] = loaded
	set.fallback_count += 1
	return &set.fallbacks[set.fallback_count - 1], {}
}

record_fallback_miss :: proc(set: ^Set, codepoint: rune) {
	if set.miss_count < MAX_FALLBACK_MISSES {
		set.misses[set.miss_count] = codepoint
		set.miss_count += 1
	}
}

location_destroy :: proc(location: ^Location, allocator := context.allocator) {
	delete(location.path, allocator)
	delete(location.family, allocator)
	location^ = Location{}
}

is_generic_family :: proc(family: string) -> bool {
	generic := [?]string{"monospace", "sans", "sans-serif", "serif", "system-ui", "emoji"}
	for candidate in generic {
		if strings.equal_fold(family, candidate) {
			return true
		}
	}
	return false
}


native_ascender :: proc(native: rawptr, pixel_size: u32) -> i64 {
	face := ft.Face(native)
	if face == nil || face.size == nil || pixel_size == 0 {
		return 0
	}
	return i64(face.size.metrics.ascender)
}
