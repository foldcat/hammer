package command

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import errs "../errs"

MAX_FILTER_COMMANDS :: 64
MAX_FILTER_NAME_BYTES :: 64
MAX_FILTER_ENGINE_BYTES :: 64
MAX_FILTER_BODY_BYTES :: 64 * 1024
MAX_FILTER_ORIGIN_BYTES :: 4096
MAX_FILTER_PATH_BYTES :: 4096
MAX_FILTER_PATH_DIRS :: 128
MAX_FILTER_DISCOVERY_ENTRIES :: 4096
MAX_FILTER_DISCOVERY_FILES :: MAX_FILTER_COMMANDS

Filter_Scope :: enum u8 {
	User,
	Project,
	Session,
}

Filter_Routing :: enum u8 {
	Replace_Selection,
	Output_Window,
	Discard,
}

// Filter_Definition contains declarative metadata only. body is never executed
// by parsing, registration, discovery, lookup, validation, or enumeration.
Filter_Definition :: struct {
	name:        string,
	engine:      string,
	body:        string,
	raku_mode:   string,
	origin:      string,
	engine_path: string,
	scope:       Filter_Scope,
	routing:     Filter_Routing,
}

Filter_Registry_Options :: struct {
	path: string,
}

// Filter_Registry owns every definition string and its PATH snapshot. It is a
// fixed-location value; destroy before reinitialization and do not copy it.
Filter_Registry :: struct {
	initialized: bool,
	allocator:   runtime.Allocator,
	path:        string,
	entries:     [MAX_FILTER_COMMANDS]Filter_Definition,
	count:       int,
}

filter_scope_name :: proc(scope: Filter_Scope) -> string {
	switch scope {
	case .User:
		return "user"
	case .Project:
		return "project"
	case .Session:
		return "session"
	}
	return "unknown"
}

filter_routing_name :: proc(routing: Filter_Routing) -> string {
	switch routing {
	case .Replace_Selection:
		return "replace-selection"
	case .Output_Window:
		return "output-window"
	case .Discard:
		return "discard"
	}
	return "unknown"
}

filter_routing_parse :: proc(text: string) -> (Filter_Routing, bool) {
	switch text {
	case "replace-selection":
		return .Replace_Selection, true
	case "output-window":
		return .Output_Window, true
	case "discard":
		return .Discard, true
	}
	return {}, false
}

filter_definition_destroy :: proc(definition: ^Filter_Definition, allocator: runtime.Allocator) {
	if definition == nil {
		return
	}
	delete(definition.name, allocator)
	delete(definition.engine, allocator)
	delete(definition.body, allocator)
	delete(definition.raku_mode, allocator)
	delete(definition.origin, allocator)
	delete(definition.engine_path, allocator)
	definition^ = {}
}

filter_registry_init :: proc(registry: ^Filter_Registry, options: Filter_Registry_Options = {}, allocator := context.allocator) -> errs.Error {
	if registry == nil {
		return errs.new(.Invalid_Input, "filter: nil registry", allocator = allocator)
	}
	if registry.initialized {
		return errs.new(.Conflict, "filter: registry is already initialized", allocator = allocator)
	}
	if len(options.path) > MAX_FILTER_PATH_BYTES {
		return errs.new(.Resource_Limit, "filter: PATH snapshot is too long", allocator = allocator)
	}
	path, clone_err := strings.clone(options.path, allocator)
	if clone_err != nil {
		return errs.new(.Resource_Limit, "filter: cannot copy PATH snapshot", allocator = allocator)
	}
	registry^ = {initialized = true, allocator = allocator, path = path}
	return {}
}

filter_registry_destroy :: proc(registry: ^Filter_Registry) {
	if registry == nil {
		return
	}
	for index in 0 ..< registry.count {
		filter_definition_destroy(&registry.entries[index], registry.allocator)
	}
	delete(registry.path, registry.allocator)
	registry^ = {}
}

filter_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_FILTER_NAME_BYTES {
		return false
	}
	for char, index in name {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') {
			continue
		}
		if index > 0 && (char == '-' || char == '_' || char == '.') {
			continue
		}
		return false
	}
	return true
}

filter_engine_valid :: proc(engine: string) -> bool {
	if len(engine) == 0 || len(engine) > MAX_FILTER_ENGINE_BYTES {
		return false
	}
	for char in engine {
		if char == '/' || char == '\\' || char == 0 || char == '\n' || char == '\r' || char == '\t' || char == ' ' {
			return false
		}
	}
	return true
}

filter_validate :: proc(definition: Filter_Definition, allocator := context.allocator) -> errs.Error {
	if !filter_name_valid(definition.name) {
		return errs.new(.Invalid_Input, "filter: name must be 1..64 letters, digits, '.', '_', or '-', starting alphanumeric", allocator = allocator)
	}
	if !filter_engine_valid(definition.engine) {
		return errs.new(.Invalid_Input, "filter: engine must be a nonempty executable name without path separators or whitespace", allocator = allocator)
	}
	if len(definition.body) == 0 {
		return errs.new(.Invalid_Input, "filter: body must not be empty", allocator = allocator)
	}
	if len(definition.body) > MAX_FILTER_BODY_BYTES {
		return errs.new(.Resource_Limit, "filter: body exceeds the 64 KiB budget", allocator = allocator)
	}
	if len(definition.origin) > MAX_FILTER_ORIGIN_BYTES {
		return errs.new(.Resource_Limit, "filter: origin path is too long", allocator = allocator)
	}
	if !raku_program_mode_valid(definition.raku_mode) || (definition.raku_mode != "" && definition.engine != "raku") {
		return errs.new(.Invalid_Input, "filter: raku mode must be empty, -n, or -p and requires engine raku", allocator = allocator)
	}
	if definition.scope != .User && definition.scope != .Project && definition.scope != .Session {
		return errs.new(.Invalid_Input, "filter: invalid definition scope", allocator = allocator)
	}
	if definition.routing != .Replace_Selection && definition.routing != .Output_Window && definition.routing != .Discard {
		return errs.new(.Invalid_Input, "filter: invalid output routing", allocator = allocator)
	}
	return {}
}

filter_definition_clone :: proc(source: Filter_Definition, allocator: runtime.Allocator) -> (definition: Filter_Definition, err: errs.Error) {
	succeeded := false
	defer if !succeeded {
		filter_definition_destroy(&definition, allocator)
	}
	definition.scope = source.scope
	definition.routing = source.routing
	definition.name = strings.clone(source.name, allocator)
	definition.engine = strings.clone(source.engine, allocator)
	definition.body = strings.clone(source.body, allocator)
	definition.raku_mode = strings.clone(source.raku_mode, allocator)
	definition.origin = strings.clone(source.origin, allocator)
	definition.engine_path = strings.clone(source.engine_path, allocator)
	if (len(source.name) > 0 && definition.name == "") || (len(source.engine) > 0 && definition.engine == "") ||
		(len(source.body) > 0 && definition.body == "") || (len(source.raku_mode) > 0 && definition.raku_mode == "") ||
		(len(source.origin) > 0 && definition.origin == "") || (len(source.engine_path) > 0 && definition.engine_path == "") {
		err = errs.new(.Resource_Limit, "filter: cannot copy command definition", allocator = allocator)
		return
	}
	succeeded = true
	return
}

filter_registry_register :: proc(registry: ^Filter_Registry, definition: Filter_Definition) -> errs.Error {
	if registry == nil || !registry.initialized {
		return errs.new(.Invalid_Input, "filter: registry is not initialized")
	}
	if err := filter_validate(definition, registry.allocator); !errs.ok(err) {
		return err
	}
	for entry in registry.entries[:registry.count] {
		if entry.scope == definition.scope && entry.name == definition.name {
			return errs.newf(.Conflict, "filter: %s command %q is already registered", filter_scope_name(definition.scope), definition.name, allocator = registry.allocator)
		}
	}
	if registry.count == MAX_FILTER_COMMANDS {
		return errs.newf(.Resource_Limit, "filter: no more than %d commands may be registered", MAX_FILTER_COMMANDS, allocator = registry.allocator)
	}
	owned, clone_err := filter_definition_clone(definition, registry.allocator)
	if !errs.ok(clone_err) {
		return clone_err
	}
	succeeded := false
	defer if !succeeded {
		filter_definition_destroy(&owned, registry.allocator)
	}
	engine_path, resolve_err := filter_engine_resolve(registry, owned.engine)
	if !errs.ok(resolve_err) {
		return resolve_err
	}
	owned.engine_path = engine_path
	registry.entries[registry.count] = owned
	registry.count += 1
	succeeded = true
	return {}
}

filter_registry_clone_into :: proc(destination, source: ^Filter_Registry, scope: Filter_Scope) -> errs.Error {
	for entry in source.entries[:source.count] {
		if entry.scope != scope {
			continue
		}
		if destination.count == MAX_FILTER_COMMANDS {
			return errs.new(.Resource_Limit, "filter: command capacity exceeded during scope replacement", allocator = destination.allocator)
		}
		owned, clone_err := filter_definition_clone(entry, destination.allocator)
		if !errs.ok(clone_err) {
			return clone_err
		}
		destination.entries[destination.count] = owned
		destination.count += 1
	}
	return {}
}

filter_registry_clear_scope :: proc(registry: ^Filter_Registry, scope: Filter_Scope) -> errs.Error {
	if registry == nil || !registry.initialized {
		return errs.new(.Invalid_Input, "filter: registry is not initialized")
	}
	if scope != .User && scope != .Project && scope != .Session {
		return errs.new(.Invalid_Input, "filter: invalid discovery scope", allocator = registry.allocator)
	}
	next: Filter_Registry
	if err := filter_registry_init(&next, {path = registry.path}, registry.allocator); !errs.ok(err) {
		return err
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
		if err := filter_registry_clone_into(&next, registry, other_scope); !errs.ok(err) {
			return err
		}
	}
	filter_registry_destroy(registry)
	registry^ = next
	succeeded = true
	return {}
}

// The returned definition is borrowed until the next registry mutation.
filter_registry_find :: proc(registry: ^Filter_Registry, name: string) -> ^Filter_Definition {
	if registry == nil || !registry.initialized {
		return nil
	}
	precedence := []Filter_Scope{.Session, .Project, .User}
	for scope in precedence {
		for &entry in registry.entries[:registry.count] {
			if entry.scope == scope && entry.name == name {
				return &entry
			}
		}
	}
	return nil
}

filter_registry_available_count :: proc(registry: ^Filter_Registry) -> int {
	if registry == nil || !registry.initialized {
		return 0
	}
	count := 0
	for entry in registry.entries[:registry.count] {
		if entry.engine_path != "" {
			count += 1
		}
	}
	return count
}

// filter_command builds the argument vector for invoking a resolved
// definition: the engine executable (argv[0]) followed by the raw body as a
// single program argument (argv[1]). The engine interprets that program
// argument; engine-specific adapters (for example Raku's -e/temp-file
// convention) are a later milestone. A definition whose engine path is still
// unresolved cannot be invoked. The caller owns the returned slice and each
// element and must release them with filter_command_destroy.
filter_command :: proc(definition: ^Filter_Definition, allocator := context.allocator) -> ([]string, errs.Error) {
	if definition == nil {
		return nil, errs.new(.Invalid_Input, "filter: nil command definition", allocator = allocator)
	}
	if definition.engine_path == "" {
		return nil, errs.new(.Unsupported, "filter: command engine is not available", allocator = allocator)
	}
	argv, alloc_err := make([]string, 2, allocator)
	if alloc_err != nil {
		return nil, errs.new(.Resource_Limit, "filter: cannot allocate command vector", allocator = allocator)
	}
	argv[0] = strings.clone(definition.engine_path, allocator)
	argv[1] = strings.clone(definition.body, allocator)
	if argv[0] == "" || argv[1] == "" {
		delete(argv[0], allocator)
		delete(argv[1], allocator)
		delete(argv, allocator)
		return nil, errs.new(.Resource_Limit, "filter: cannot copy command vector", allocator = allocator)
	}
	return argv, {}
}

// filter_command_destroy releases an owned vector produced by filter_command.
filter_command_destroy :: proc(argv: []string, allocator := context.allocator) {
	if len(argv) >= 1 {
		delete(argv[0], allocator)
	}
	if len(argv) >= 2 {
		delete(argv[1], allocator)
	}
	delete(argv, allocator)
}

// Enumeration returns an owned, deterministic report. The sorted definitions
// are shallow read-only copies; their strings remain registry-owned.
filter_registry_describe :: proc(registry: ^Filter_Registry, allocator := context.allocator) -> (report: string, err: errs.Error) {
	if registry == nil || !registry.initialized {
		return "", errs.new(.Invalid_Input, "filter: registry is not initialized", allocator = allocator)
	}
	ordered, alloc_err := make([]Filter_Definition, registry.count, allocator)
	if alloc_err != nil {
		return "", errs.new(.Resource_Limit, "filter: cannot allocate command enumeration", allocator = allocator)
	}
	defer delete(ordered, allocator)
	copy(ordered, registry.entries[:registry.count])
	slice.sort_by(ordered, proc(left, right: Filter_Definition) -> bool {
		if left.name != right.name {
			return left.name < right.name
		}
		return left.scope < right.scope
	})
	result := make([dynamic]byte, allocator)
	defer if !errs.ok(err) {
		delete(result)
	}
	header := fmt.aprintf("%d named filter command(s); %d engine(s) available\n", registry.count, filter_registry_available_count(registry), allocator = allocator)
	if header == "" {
		return "", errs.new(.Resource_Limit, "filter: cannot format command enumeration", allocator = allocator)
	}
	_, header_append_err := append(&result, ..transmute([]byte)header)
	delete(header, allocator)
	if header_append_err != .None {
		return "", errs.new(.Resource_Limit, "filter: cannot grow command enumeration", allocator = allocator)
	}
	for definition in ordered {
		origin := definition.origin
		if origin == "" {
			origin = "<session>"
		}
		availability := "missing"
		if definition.engine_path != "" {
			availability = definition.engine_path
		}
		mode := definition.raku_mode
		if mode == "" {
			mode = "-"
		}
		line := fmt.aprintf(
			"%s  scope=%s  engine=%s  available=%s  routing=%s  raku=%s  origin=%s\n",
			definition.name,
			filter_scope_name(definition.scope),
			definition.engine,
			availability,
			filter_routing_name(definition.routing),
			mode,
			origin,
			allocator = allocator,
		)
		if line == "" {
			return "", errs.new(.Resource_Limit, "filter: cannot format command definition", allocator = allocator)
		}
		_, line_append_err := append(&result, ..transmute([]byte)line)
		delete(line, allocator)
		if line_append_err != .None {
			return "", errs.new(.Resource_Limit, "filter: cannot grow command enumeration", allocator = allocator)
		}
	}
	return string(result[:]), {}
}
