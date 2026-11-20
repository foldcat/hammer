package command

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import errs "../errs"

filter_engine_file :: proc(path: string, allocator := context.allocator) -> bool {
	info, stat_err := os.stat(path, allocator)
	if stat_err != nil {
		return false
	}
	defer os.file_info_delete(info, allocator)
	if info.type != .Regular {
		return false
	}
	when ODIN_OS == .Windows {
		return true
	} else {
		return info.mode & os.Permissions_Execute_All != {}
	}
}

filter_engine_resolve :: proc(registry: ^Filter_Registry, engine: string) -> (string, errs.Error) {
	allocator := registry.allocator
	directories, split_err := os.split_path_list(registry.path, allocator)
	if split_err != nil {
		return "", errs.newf(.Resource_Limit, "filter: cannot split PATH for %s: %v", engine, split_err, allocator = allocator)
	}
	defer {
		for directory in directories {
			delete(directory, allocator)
		}
		delete(directories, allocator)
	}
	if len(directories) > MAX_FILTER_PATH_DIRS {
		return "", errs.newf(.Resource_Limit, "filter: PATH exceeds the %d-directory budget", MAX_FILTER_PATH_DIRS, allocator = allocator)
	}
	extensions := []string{""}
	when ODIN_OS == .Windows {
		extensions = []string{"", ".exe"}
	}
	for directory in directories {
		for extension in extensions {
			filename := ""
			if extension == "" {
				filename = engine
			} else {
				joined, join_err := strings.concatenate({engine, extension}, allocator)
				if join_err != nil {
					return "", errs.new(.Resource_Limit, "filter: cannot construct engine candidate", allocator = allocator)
				}
				filename = joined
			}
			candidate := ""
			if directory == "" {
				cloned, clone_err := strings.clone(filename, allocator)
				if clone_err != nil {
					if extension != "" {
						delete(filename, allocator)
					}
					return "", errs.new(.Resource_Limit, "filter: cannot copy engine candidate", allocator = allocator)
				}
				candidate = cloned
			} else {
				joined, join_err := os.join_path({directory, filename}, allocator)
				if join_err != .None {
					if extension != "" {
						delete(filename, allocator)
					}
					return "", errs.new(.Resource_Limit, "filter: cannot construct engine path", allocator = allocator)
				}
				candidate = joined
			}
			if extension != "" {
				delete(filename, allocator)
			}
			if len(candidate) > MAX_FILTER_PATH_BYTES {
				delete(candidate, allocator)
				return "", errs.new(.Resource_Limit, "filter: engine path is too long", allocator = allocator)
			}
			if filter_engine_file(candidate, allocator) {
				return candidate, {}
			}
			delete(candidate, allocator)
		}
	}
	return "", {}
}

filter_user_directory :: proc(allocator := context.allocator) -> (string, errs.Error) {
	base := ""
	when ODIN_OS == .Windows {
		base = os.get_env("APPDATA", allocator)
	} else {
		base = os.get_env("XDG_CONFIG_HOME", allocator)
		if base == "" {
			home := os.get_env("HOME", allocator)
			defer delete(home, allocator)
			if home != "" {
				joined, join_err := strings.concatenate({home, "/.config"}, allocator)
				if join_err != nil {
					return "", errs.new(.Resource_Limit, "filter: cannot construct user config path", allocator = allocator)
				}
				base = joined
			}
		}
	}
	defer delete(base, allocator)
	if base == "" {
		return "", {}
	}
	path, join_err := os.join_path({base, "hammer", "commands"}, allocator)
	if join_err != .None {
		return "", errs.new(.Resource_Limit, "filter: cannot construct user command path", allocator = allocator)
	}
	return path, {}
}

filter_project_directory :: proc(project_root: string, allocator := context.allocator) -> (string, errs.Error) {
	if project_root == "" {
		return "", errs.new(.Invalid_Input, "filter: project root is empty", allocator = allocator)
	}
	path, join_err := os.join_path({project_root, ".hammer", "commands"}, allocator)
	if join_err != .None {
		return "", errs.new(.Resource_Limit, "filter: cannot construct project command path", allocator = allocator)
	}
	return path, {}
}

filter_discovery_paths_destroy :: proc(paths: ^[dynamic]string, allocator: runtime.Allocator) {
	for path in paths^ {
		delete(path, allocator)
	}
	delete(paths^)
}

// Scope replacement is atomic: the old registry remains intact if allocation,
// directory traversal, parsing, validation, or registration fails.
filter_registry_load_directory :: proc(registry: ^Filter_Registry, scope: Filter_Scope, path: string) -> (err: errs.Error) {
	if registry == nil || !registry.initialized {
		return errs.new(.Invalid_Input, "filter: registry is not initialized")
	}
	if scope != .User && scope != .Project && scope != .Session {
		return errs.new(.Invalid_Input, "filter: invalid discovery scope", allocator = registry.allocator)
	}
	if path == "" || len(path) > MAX_FILTER_PATH_BYTES {
		return errs.new(.Invalid_Input, "filter: discovery path is empty or too long", allocator = registry.allocator)
	}
	allocator := registry.allocator
	next: Filter_Registry
	if init_err := filter_registry_init(&next, {path = registry.path}, allocator); !errs.ok(init_err) {
		return init_err
	}
	succeeded := false
	defer if !succeeded {
		filter_registry_destroy(&next)
	}
	scopes := []Filter_Scope{.User, .Project, .Session}
	for other_scope in scopes {
		if other_scope == scope {
			continue
		}
		if clone_err := filter_registry_clone_into(&next, registry, other_scope); !errs.ok(clone_err) {
			return clone_err
		}
	}

	directory_file, open_err := os.open(path, {.Read})
	if open_err != nil {
		kind := errs.Kind.IO
		if open_err == .Not_Exist {
			kind = .NotFound
		}
		return errs.newf(kind, "filter: cannot open command directory %s: %v", path, open_err, allocator = allocator)
	}
	defer os.close(directory_file)
	info, stat_err := os.fstat(directory_file, allocator)
	if stat_err != nil {
		return errs.newf(.IO, "filter: cannot stat command directory %s: %v", path, stat_err, allocator = allocator)
	}
	defer os.file_info_delete(info, allocator)
	if info.type != .Directory {
		return errs.new(.Invalid_Input, "filter: command discovery path is not a directory", allocator = allocator)
	}

	paths := make([dynamic]string, allocator)
	defer filter_discovery_paths_destroy(&paths, allocator)
	iterator := os.read_directory_iterator_create(directory_file)
	defer os.read_directory_iterator_destroy(&iterator)
	scanned := 0
	for entry in os.read_directory_iterator(&iterator) {
		if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
			return errs.newf(.IO, "filter: cannot read command entry %s: %v", error_path, iter_err, allocator = allocator)
		}
		scanned += 1
		if scanned > MAX_FILTER_DISCOVERY_ENTRIES {
			return errs.newf(.Resource_Limit, "filter: %s exceeds the %d-entry discovery budget", path, MAX_FILTER_DISCOVERY_ENTRIES, allocator = allocator)
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".filter") {
			continue
		}
		if !utf8.valid_string(entry.name) {
			return errs.new(.Unsupported, "filter: command filename is not valid UTF-8", allocator = allocator)
		}
		if entry.size > MAX_FILTER_BODY_BYTES {
			return errs.newf(.Resource_Limit, "filter: %s exceeds the %d-byte definition budget", entry.fullpath, MAX_FILTER_BODY_BYTES, allocator = allocator)
		}
		if len(paths) == MAX_FILTER_DISCOVERY_FILES {
			return errs.newf(.Resource_Limit, "filter: %s exceeds the %d-file discovery budget", path, MAX_FILTER_DISCOVERY_FILES, allocator = allocator)
		}
		source_path := entry.fullpath
		if source_path == "" {
			joined, join_err := os.join_path({path, entry.name}, allocator)
			if join_err != .None {
				return errs.new(.Resource_Limit, "filter: cannot construct definition path", allocator = allocator)
			}
			source_path = joined
		}
		owned, clone_err := strings.clone(source_path, allocator)
		if source_path != entry.fullpath {
			delete(source_path, allocator)
		}
		if clone_err != nil {
			return errs.new(.Resource_Limit, "filter: cannot copy definition path", allocator = allocator)
		}
		_, append_err := append(&paths, owned)
		if append_err != .None {
			delete(owned, allocator)
			return errs.new(.Resource_Limit, "filter: cannot grow discovery list", allocator = allocator)
		}
	}
	if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
		return errs.newf(.IO, "filter: cannot finish command scan %s: %v", error_path, iter_err, allocator = allocator)
	}
	slice.sort_by(paths[:], proc(left, right: string) -> bool {
		return left < right
	})
	for definition_path in paths {
		data, read_err := os.read_entire_file(definition_path, allocator)
		if read_err != nil {
			return errs.newf(.IO, "filter: cannot read %s: %v", definition_path, read_err, allocator = allocator)
		}
		definition, parse_err := filter_parse_definition(string(data), definition_path, scope, allocator)
		delete(data, allocator)
		if !errs.ok(parse_err) {
			return parse_err
		}
		if register_err := filter_registry_register(&next, definition); !errs.ok(register_err) {
			return register_err
		}
	}
	filter_registry_destroy(registry)
	registry^ = next
	succeeded = true
	return {}
}
