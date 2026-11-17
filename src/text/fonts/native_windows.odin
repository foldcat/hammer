#+build windows

package fonts

import "core:os"
import "core:strings"
import "core:sys/windows"

import errs "../../core/errs"
import dw "../directwrite"

MAX_PATH_BYTES :: 4096
MAX_FAMILIES :: 4
MAX_FAMILY_BYTES :: 64
MAX_SYSTEM_FONT_FAMILIES :: 4096

Impl :: struct {
	factory:    ^dw.Factory,
	collection: ^dw.Font_Collection,
	analyzer:   ^dw.Text_Analyzer,
}

Location :: struct {
	path:       string,
	family:     string,
	face_index: int,
	font:       ^dw.Font,
}

init :: proc(set: ^Set, options: Options, allocator := context.allocator) -> errs.Error {
	set^ = Set{allocator = allocator}
	if err := validate_options(options, allocator); !errs.ok(err) {
		return err
	}
	if options.config_path != "" {
		return errs.new(.Unsupported, "fontconfig paths are not used by the Windows font adapter", allocator = allocator)
	}

	factory, status := dw.create_factory()
	if !dw.succeeded(status) || factory == nil {
		return hresult_error(.IO, "DirectWrite factory creation failed", status, allocator)
	}
	set.impl.factory = factory
	if status = factory.vtable.get_system_font_collection(factory, &set.impl.collection, false); !dw.succeeded(status) || set.impl.collection == nil {
		destroy(set)
		return hresult_error(.IO, "DirectWrite could not open the system font collection", status, allocator)
	}
	if status = factory.vtable.create_text_analyzer(factory, &set.impl.analyzer); !dw.succeeded(status) || set.impl.analyzer == nil {
		destroy(set)
		return hresult_error(.IO, "DirectWrite could not create a text analyzer", status, allocator)
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
		for requested_family in role_options.families {
			family := generic_family(requested_family)
			location, found, discover_err := discover_family(set, family, allocator)
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
	return {}
}

destroy :: proc(set: ^Set) {
	for i in 0 ..< ROLE_COUNT {
		face_destroy(set, &set.faces[i])
	}
	for i in 0 ..< set.fallback_count {
		face_destroy(set, &set.fallbacks[i])
	}
	dw.release(set.impl.analyzer)
	dw.release(set.impl.collection)
	dw.release(set.impl.factory)
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
	return {}
}

validate_path :: proc(path, what: string, allocator := context.allocator) -> errs.Error {
	if len(path) > MAX_PATH_BYTES || strings.contains(path, "\x00") {
		return errs.newf(.Invalid_Input, "%s is too long or contains NUL", what, allocator = allocator)
	}
	return {}
}

generic_family :: proc(family: string) -> string {
	switch {
	case strings.equal_fold(family, "monospace"):
		return "Consolas"
	case strings.equal_fold(family, "sans"), strings.equal_fold(family, "sans-serif"), strings.equal_fold(family, "system-ui"):
		return "Segoe UI"
	case strings.equal_fold(family, "serif"):
		return "Cambria"
	case strings.equal_fold(family, "emoji"):
		return "Segoe UI Emoji"
	}
	return family
}

discover_family :: proc(set: ^Set, family: string, allocator := context.allocator) -> (Location, bool, errs.Error) {
	wide := windows.utf8_to_wstring(family, allocator)
	if wide == nil {
		return {}, false, errs.new(.Resource_Limit, "cannot allocate a DirectWrite family query", allocator = allocator)
	}
	defer delete(wide, allocator)
	index: u32
	exists: windows.BOOL
	status := set.impl.collection.vtable.find_family_name(set.impl.collection, wide, &index, &exists)
	if !dw.succeeded(status) {
		return {}, false, hresult_error(.IO, "DirectWrite family lookup failed", status, allocator)
	}
	if !exists {
		return {}, false, {}
	}
	font_family: ^dw.Font_Family
	if status = set.impl.collection.vtable.get_font_family(set.impl.collection, index, &font_family); !dw.succeeded(status) || font_family == nil {
		return {}, false, hresult_error(.IO, "DirectWrite could not open the matched font family", status, allocator)
	}
	defer dw.release(font_family)
	name, name_err := localized_family_name(font_family, allocator)
	if !errs.ok(name_err) {
		return {}, false, name_err
	}
	font: ^dw.Font
	if status = font_family.vtable.get_first_matching_font(font_family, 400, 5, 0, &font); !dw.succeeded(status) || font == nil {
		delete(name, allocator)
		return {}, false, hresult_error(.IO, "DirectWrite could not select a regular font", status, allocator)
	}
	return Location{family = name, font = font}, true, {}
}

localized_family_name :: proc(family: ^dw.Font_Family, allocator := context.allocator) -> (string, errs.Error) {
	names: ^dw.Localized_Strings
	status := family.vtable.get_family_names(family, &names)
	if !dw.succeeded(status) || names == nil {
		return "", hresult_error(.IO, "DirectWrite could not read font family names", status, allocator)
	}
	defer dw.release(names)
	if names.vtable.get_count(names) == 0 {
		return "", errs.new(.Invalid_Input, "DirectWrite returned an empty font family name list", allocator = allocator)
	}
	length: u32
	if status = names.vtable.get_string_length(names, 0, &length); !dw.succeeded(status) || length == 0 || length > MAX_FAMILY_BYTES {
		return "", hresult_error(.Invalid_Input, "DirectWrite returned an invalid font family name length", status, allocator)
	}
	units := make([]u16, int(length) + 1, allocator)
	defer delete(units, allocator)
	if status = names.vtable.get_string(names, 0, raw_data(units), length + 1); !dw.succeeded(status) {
		return "", hresult_error(.IO, "DirectWrite could not copy a font family name", status, allocator)
	}
	name, alloc_err := windows.utf16_to_utf8(units[:length], allocator)
	if alloc_err != nil || name == "" {
		return "", errs.new(.Resource_Limit, "cannot allocate a DirectWrite family name", allocator = allocator)
	}
	return name, {}
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
	face: ^dw.Font_Face
	if location.font != nil {
		status := location.font.vtable.create_font_face(location.font, &face)
		if !dw.succeeded(status) || face == nil {
			return {}, hresult_error(.IO, "DirectWrite could not create the selected font face", status, set.allocator)
		}
	} else {
		absolute, path_err := os.get_absolute_path(location.path, set.allocator)
		if path_err != nil {
			return {}, errs.newf(.IO, "cannot resolve the %s font path %s", role_name(role), location.path, allocator = set.allocator)
		}
		defer delete(absolute, set.allocator)
		wide := windows.utf8_to_wstring(absolute, set.allocator)
		if wide == nil {
			return {}, errs.new(.Resource_Limit, "cannot allocate a DirectWrite font path", allocator = set.allocator)
		}
		defer delete(wide, set.allocator)
		file: ^dw.Font_File
		status := set.impl.factory.vtable.create_font_file_reference(set.impl.factory, wide, nil, &file)
		if !dw.succeeded(status) || file == nil {
			return {}, hresult_error(.IO, "DirectWrite could not reference the explicit font file", status, set.allocator)
		}
		defer dw.release(file)
		supported: windows.BOOL
		file_type: i32
		face_type: dw.Font_Face_Type
		face_count: u32
		status = file.vtable.analyze(file, &supported, &file_type, &face_type, &face_count)
		if !dw.succeeded(status) || !supported || location.face_index < 0 || u32(location.face_index) >= face_count {
			return {}, errs.newf(.IO, "cannot load %s font %s (DirectWrite status %d)", role_name(role), location.path, status, allocator = set.allocator)
		}
		files := [1]^dw.Font_File{file}
		status = set.impl.factory.vtable.create_font_face(set.impl.factory, face_type, 1, raw_data(files[:]), u32(location.face_index), .None, &face)
		if !dw.succeeded(status) || face == nil {
			return {}, hresult_error(.IO, "DirectWrite could not open the explicit font face", status, set.allocator)
		}
	}

	path := location.path
	owned_path := ""
	if path == "" {
		discovered_path, path_error := face_path(face, set.allocator)
		if !errs.ok(path_error) {
			dw.release(face)
			return {}, path_error
		}
		owned_path = discovered_path
		path = owned_path
	}
	family := location.family
	if family == "" {
		family = path
	}
	native := new(dw.Native_Face, set.allocator)
	native^ = {face = face, factory = set.impl.factory, analyzer = set.impl.analyzer}
	loaded := Face{
		role = role,
		cache_id = cache_id,
		path = strings.clone(path, set.allocator),
		family = strings.clone(family, set.allocator),
		face_index = int(face.vtable.get_index(face)),
		native = rawptr(native),
	}
	if owned_path != "" {
		delete(owned_path, set.allocator)
	}
	return loaded, {}
}

face_path :: proc(face: ^dw.Font_Face, allocator := context.allocator) -> (string, errs.Error) {
	count: u32
	status := face.vtable.get_files(face, &count, nil)
	if !dw.succeeded(status) || count != 1 {
		return "", hresult_error(.Unsupported, "only single-file DirectWrite faces are supported", status, allocator)
	}
	files := [1]^dw.Font_File{}
	if status = face.vtable.get_files(face, &count, raw_data(files[:])); !dw.succeeded(status) || files[0] == nil {
		return "", hresult_error(.IO, "DirectWrite could not open the font file reference", status, allocator)
	}
	defer dw.release(files[0])
	key: rawptr
	key_size: u32
	if status = files[0].vtable.get_reference_key(files[0], &key, &key_size); !dw.succeeded(status) || key == nil || key_size == 0 {
		return "", hresult_error(.IO, "DirectWrite returned an invalid font file key", status, allocator)
	}
	loader: ^dw.Font_File_Loader
	if status = files[0].vtable.get_loader(files[0], &loader); !dw.succeeded(status) || loader == nil {
		return "", hresult_error(.IO, "DirectWrite returned no font file loader", status, allocator)
	}
	defer dw.release(loader)
	local_raw: rawptr
	if status = dw.query_interface(loader, &dw.IID_LOCAL_FONT_FILE_LOADER, &local_raw); !dw.succeeded(status) || local_raw == nil {
		return "", hresult_error(.Unsupported, "the DirectWrite font is not a local file", status, allocator)
	}
	local := cast(^dw.Local_Font_File_Loader)local_raw
	defer dw.release(local)
	length: u32
	if status = local.vtable.get_file_path_length_from_key(local, key, key_size, &length); !dw.succeeded(status) || length == 0 || length > MAX_PATH_BYTES {
		return "", hresult_error(.Invalid_Input, "DirectWrite returned an invalid font path length", status, allocator)
	}
	units := make([]u16, int(length) + 1, allocator)
	defer delete(units, allocator)
	if status = local.vtable.get_file_path_from_key(local, key, key_size, raw_data(units), length + 1); !dw.succeeded(status) {
		return "", hresult_error(.IO, "DirectWrite could not copy the font path", status, allocator)
	}
	path, alloc_err := windows.utf16_to_utf8(units[:length], allocator)
	if alloc_err != nil || path == "" {
		return "", errs.new(.Resource_Limit, "cannot allocate a DirectWrite font path", allocator = allocator)
	}
	return path, {}
}

face_destroy :: proc(set: ^Set, face: ^Face) {
	if face.native != nil {
		native := cast(^dw.Native_Face)face.native
		dw.release(native.face)
		free(native, set.allocator)
	}
	if face.path != "" {
		delete(face.path, set.allocator)
	}
	if face.family != "" {
		delete(face.family, set.allocator)
	}
	face^ = Face{}
}

face_char_index :: proc(face: ^Face, codepoint: rune, allocator := context.allocator) -> (u32, errs.Error) {
	if face == nil || face.native == nil {
		return 0, errs.new(.Invalid_Input, "DirectWrite glyph lookup requires a face", allocator = allocator)
	}
	native := cast(^dw.Native_Face)face.native
	points := [1]u32{u32(codepoint)}
	indices := [1]u16{}
	status := native.face.vtable.get_glyph_indices(native.face, raw_data(points[:]), 1, raw_data(indices[:]))
	if !dw.succeeded(status) {
		return 0, hresult_error(.IO, "DirectWrite glyph lookup failed", status, allocator)
	}
	return u32(indices[0]), {}
}

ensure_fallback :: proc(set: ^Set, codepoint: rune) -> (^Face, errs.Error) {
	if set == nil || set.impl.factory == nil || set.impl.collection == nil {
		return nil, errs.new(.Invalid_Input, "font fallback requires an initialized font set", allocator = set.allocator if set != nil else context.allocator)
	}
	if codepoint < 0 || codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff {
		return nil, errs.new(.Invalid_Input, "font fallback requires a Unicode scalar value", allocator = set.allocator)
	}
	shaping_roles := [2]Role{.Body, .Emoji}
	for role in shaping_roles {
		candidate := &set.faces[int(role)]
		if candidate.native == nil {
			continue
		}
		index, err := face_char_index(candidate, codepoint, set.allocator)
		if !errs.ok(err) {
			return nil, err
		}
		if index != 0 {
			return candidate, {}
		}
	}
	for index in 0 ..< set.fallback_count {
		candidate := &set.fallbacks[index]
		glyph, err := face_char_index(candidate, codepoint, set.allocator)
		if !errs.ok(err) {
			return nil, err
		}
		if glyph != 0 {
			return candidate, {}
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

	family_count := set.impl.collection.vtable.get_font_family_count(set.impl.collection)
	if family_count > MAX_SYSTEM_FONT_FAMILIES {
		return nil, errs.new(.Resource_Limit, "the Windows font collection exceeds the fallback search budget", allocator = set.allocator)
	}
	for family_index in 0 ..< family_count {
		family: ^dw.Font_Family
		status := set.impl.collection.vtable.get_font_family(set.impl.collection, family_index, &family)
		if !dw.succeeded(status) || family == nil {
			return nil, hresult_error(.IO, "DirectWrite fallback family enumeration failed", status, set.allocator)
		}
		font: ^dw.Font
		status = family.vtable.get_first_matching_font(family, 400, 5, 0, &font)
		dw.release(family)
		if !dw.succeeded(status) || font == nil {
			return nil, hresult_error(.IO, "DirectWrite fallback font selection failed", status, set.allocator)
		}
		exists: windows.BOOL
		status = font.vtable.has_character(font, u32(codepoint), &exists)
		if !dw.succeeded(status) {
			dw.release(font)
			return nil, hresult_error(.IO, "DirectWrite fallback coverage lookup failed", status, set.allocator)
		}
		if !exists {
			dw.release(font)
			continue
		}
		owning_family: ^dw.Font_Family
		status = font.vtable.get_font_family(font, &owning_family)
		if !dw.succeeded(status) || owning_family == nil {
			dw.release(font)
			return nil, hresult_error(.IO, "DirectWrite fallback has no owning family", status, set.allocator)
		}
		name, name_err := localized_family_name(owning_family, set.allocator)
		dw.release(owning_family)
		if !errs.ok(name_err) {
			dw.release(font)
			return nil, name_err
		}
		location := Location{font = font, family = name}
		loaded, load_err := open_face(set, .Body, location, u64(ROLE_COUNT + set.fallback_count + 1))
		delete(name, set.allocator)
		dw.release(font)
		if !errs.ok(load_err) {
			return nil, load_err
		}
		set.fallbacks[set.fallback_count] = loaded
		set.fallback_count += 1
		return &set.fallbacks[set.fallback_count - 1], {}
	}
	record_fallback_miss(set, codepoint)
	return nil, {}
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
	dw.release(location.font)
	location^ = Location{}
}

native_ascender :: proc(native: rawptr, pixel_size: u32) -> i64 {
	if native == nil || pixel_size == 0 {
		return 0
	}
	face := cast(^dw.Native_Face)native
	metrics: dw.Font_Metrics
	face.face.vtable.get_metrics(face.face, &metrics)
	if metrics.design_units_per_em == 0 {
		return 0
	}
	return i64(metrics.ascent) * i64(pixel_size) * 64 / i64(metrics.design_units_per_em)
}

hresult_error :: proc(kind: errs.Kind, message: string, status: windows.HRESULT, allocator := context.allocator) -> errs.Error {
	return errs.newf(kind, "%s (HRESULT %d)", message, i32(status), allocator = allocator)
}
