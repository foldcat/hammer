// Font discovery and role selection. A Set owns one native face per role,
// bounded codepoint fallback faces, all face path/family strings, and the
// platform discovery resources.
// Required roles are initialized all-or-nothing; the optional Emoji role may be
// absent. On error, partial resources are released. destroy is safe on zero,
// partially initialized, and fully initialized sets.
package fonts

import "base:runtime"

Role :: enum int {
	Body    = 0,
	Tag     = 1,
	Console = 2,
	Emoji   = 3,
}
ROLE_COUNT :: 4
MAX_FALLBACK_FACES :: 14
MAX_FALLBACK_MISSES :: 64

Role_Options :: struct {
	// path selects face index zero directly and takes precedence over families.
	path:     string,
	families: []string,
}

Options :: struct {
	roles: [ROLE_COUNT]Role_Options,
	// config_path is primarily for isolated tests. Empty uses the process's
	// default fontconfig configuration without modifying global state.
	config_path: string,
}

Face :: struct {
	role:       Role,
	cache_id:   u64,
	path:       string,
	family:     string,
	face_index: int,
	// Owned native FreeType face; only the platform implementation dereferences it.
	native:     rawptr,
}

Set :: struct {
	allocator:      runtime.Allocator,
	faces:          [ROLE_COUNT]Face,
	fallbacks:      [MAX_FALLBACK_FACES]Face,
	fallback_count: int,
	misses:         [MAX_FALLBACK_MISSES]rune,
	miss_count:     int,
	impl:           Impl,
}

face :: proc(set: ^Set, role: Role) -> ^Face {
	if role < .Body || int(role) >= ROLE_COUNT {
		return nil
	}
	if set.faces[int(role)].native == nil {
		return nil
	}
	return &set.faces[int(role)]
}

role_name :: proc(role: Role) -> string {
	switch role {
	case .Body:
		return "body"
	case .Tag:
		return "tag"
	case .Console:
		return "console"
	case .Emoji:
		return "emoji"
	}
	return "unknown"
}
