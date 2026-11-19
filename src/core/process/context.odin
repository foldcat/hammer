package process

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import errs "../errs"

CONTEXT_VARIABLES :: []string{
	"ACME_WINDOW_ID",
	"ACME_BUFFER_ID",
	"ACME_FILE",
	"ACME_ADDRESS",
	"ACME_PROJECT_ROOT",
	"ACME_INSTANCE_ROOT",
	"ACME_ENDPOINT",
}

Context_Description :: struct {
	window_id:         u64,
	buffer_id:         u64,
	file_path:         string,
	file_is_directory: bool,
	address:           string,
	project_root:      string,
	instance_root:     string,
	endpoint:          string,
	working_dir:       string,
	// Nil inherits a copy of the parent environment. Non-nil is the exact base
	// environment. All strings are borrowed only during context_snapshot_init.
	environment:       []string,
}

// Context_Snapshot owns working_dir, the environment slice, and every entry.
// Destroy with context_snapshot_destroy using the same allocator lifetime.
Context_Snapshot :: struct {
	allocator:   runtime.Allocator,
	working_dir: string,
	environment: []string,
}

environment_destroy :: proc(environment: []string, allocator: runtime.Allocator) {
	for entry in environment {
		delete(entry, allocator)
	}
	delete(environment, allocator)
}

environment_clone :: proc(environment: []string, allocator: runtime.Allocator) -> ([]string, errs.Error) {
	if environment == nil {
		return nil, {}
	}
	cloned, alloc_err := make([dynamic]string, 0, max(1, len(environment)), allocator)
	if alloc_err != nil {
		return nil, errs.new(.Resource_Limit, "process: cannot allocate environment snapshot", allocator = allocator)
	}
	for entry in environment {
		owned, clone_err := strings.clone(entry, allocator)
		if clone_err != nil {
			environment_destroy(cloned[:], allocator)
			return nil, errs.new(.Resource_Limit, "process: cannot copy environment snapshot", allocator = allocator)
		}
		append(&cloned, owned)
	}
	return cloned[:], {}
}

normalized_context_path :: proc(path: string, allocator: runtime.Allocator) -> (string, errs.Error) {
	if path == "" {
		cwd, cwd_err := os.get_working_directory(allocator)
		if cwd_err != nil {
			return "", errs.newf(.IO, "process: cannot determine contextual working directory: %v", cwd_err, allocator = allocator)
		}
		return cwd, {}
	}
	if os.is_absolute_path(path) {
		cleaned, clean_err := os.clean_path(path, allocator)
		if clean_err != .None {
			return "", errs.newf(.Resource_Limit, "process: cannot clean contextual path %q: %v", path, clean_err, allocator = allocator)
		}
		return cleaned, {}
	}
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		return "", errs.newf(.IO, "process: cannot determine contextual working directory: %v", cwd_err, allocator = allocator)
	}
	joined, join_err := os.join_path([]string{cwd, path}, allocator)
	delete(cwd, allocator)
	if join_err != .None {
		return "", errs.newf(.Resource_Limit, "process: cannot resolve contextual path %q: %v", path, join_err, allocator = allocator)
	}
	cleaned, clean_err := os.clean_path(joined, allocator)
	delete(joined, allocator)
	if clean_err != .None {
		return "", errs.newf(.Resource_Limit, "process: cannot clean contextual path %q: %v", path, clean_err, allocator = allocator)
	}
	return cleaned, {}
}

context_key_equal :: proc(left, right: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(left, right)
	} else {
		return left == right
	}
}

reserved_context_entry :: proc(entry: string) -> bool {
	separator := strings.index_byte(entry, '=')
	if separator <= 0 {
		return false
	}
	key := entry[:separator]
	for reserved in CONTEXT_VARIABLES {
		if context_key_equal(key, reserved) {
			return true
		}
	}
	return false
}

append_environment_entry :: proc(environment: ^[dynamic]string, entry: string, allocator: runtime.Allocator) -> errs.Error {
	owned, clone_err := strings.clone(entry, allocator)
	if clone_err != nil {
		return errs.new(.Resource_Limit, "process: cannot copy contextual environment entry", allocator = allocator)
	}
	append(environment, owned)
	return {}
}

append_context_value :: proc(environment: ^[dynamic]string, key, value: string, allocator: runtime.Allocator) -> errs.Error {
	entry := fmt.aprintf("%s=%s", key, value, allocator = allocator)
	if entry == "" {
		return errs.new(.Resource_Limit, "process: cannot format contextual environment entry", allocator = allocator)
	}
	append(environment, entry)
	return {}
}

context_snapshot_init :: proc(snapshot: ^Context_Snapshot, desc: Context_Description, allocator := context.allocator) -> errs.Error {
	if snapshot == nil {
		return errs.new(.Invalid_Input, "process: nil context snapshot", allocator = allocator)
	}
	if snapshot.environment != nil || snapshot.working_dir != "" {
		return errs.new(.Invalid_Input, "process: context snapshot is already initialized", allocator = allocator)
	}
	snapshot.allocator = allocator
	succeeded := false
	defer if !succeeded {
		context_snapshot_destroy(snapshot)
	}
	if len(desc.environment) > MAX_ENVIRONMENT_ENTRIES - len(CONTEXT_VARIABLES) {
		return errs.newf(.Resource_Limit, "process: contextual environment exceeds the %d-entry budget", MAX_ENVIRONMENT_ENTRIES, allocator = allocator)
	}

	file_path := ""
	project_root := ""
	instance_root := ""
	defer delete(file_path, allocator)
	defer delete(project_root, allocator)
	defer delete(instance_root, allocator)
	if desc.file_path != "" {
		normalized, err := normalized_context_path(desc.file_path, allocator)
		if !errs.ok(err) {
			return err
		}
		file_path = normalized
	}
	if desc.project_root != "" {
		normalized, err := normalized_context_path(desc.project_root, allocator)
		if !errs.ok(err) {
			return err
		}
		project_root = normalized
	}
	if desc.instance_root != "" {
		normalized, err := normalized_context_path(desc.instance_root, allocator)
		if !errs.ok(err) {
			return err
		}
		instance_root = normalized
	}

	working_source := desc.working_dir
	if working_source == "" && file_path != "" {
		working_source = os.dir(file_path) if !desc.file_is_directory else file_path
	}
	if working_source == "" {
		working_source = project_root
	}
	working_dir, working_err := normalized_context_path(working_source, allocator)
	if !errs.ok(working_err) {
		return working_err
	}
	snapshot.working_dir = working_dir

	inherited := []string{}
	if desc.environment == nil {
		entries, env_err := os.environ(allocator)
		if env_err != nil {
			return errs.newf(.IO, "process: cannot copy parent environment: %v", env_err, allocator = allocator)
		}
		inherited = entries
	}
	defer if desc.environment == nil {
		environment_destroy(inherited, allocator)
	}
	base := desc.environment if desc.environment != nil else inherited
	if len(base) > MAX_ENVIRONMENT_ENTRIES - len(CONTEXT_VARIABLES) {
		return errs.newf(.Resource_Limit, "process: contextual environment exceeds the %d-entry budget", MAX_ENVIRONMENT_ENTRIES, allocator = allocator)
	}
	environment, alloc_err := make([dynamic]string, 0, len(base) + len(CONTEXT_VARIABLES), allocator)
	if alloc_err != nil {
		return errs.new(.Resource_Limit, "process: cannot allocate contextual environment", allocator = allocator)
	}
	snapshot.environment = environment[:]
	for entry in base {
		if desc.environment == nil && entry == "" {
			continue
		}
		if reserved_context_entry(entry) {
			continue
		}
		if err := append_environment_entry(&environment, entry, allocator); !errs.ok(err) {
			return err
		}
		snapshot.environment = environment[:]
	}
	window_id := fmt.aprintf("%d", desc.window_id, allocator = allocator)
	buffer_id := fmt.aprintf("%d", desc.buffer_id, allocator = allocator)
	defer delete(window_id, allocator)
	defer delete(buffer_id, allocator)
	if window_id == "" || buffer_id == "" {
		return errs.new(.Resource_Limit, "process: cannot format contextual IDs", allocator = allocator)
	}
	values := []string{
		window_id,
		buffer_id,
		file_path,
		desc.address,
		project_root,
		instance_root,
		desc.endpoint,
	}
	variables := CONTEXT_VARIABLES
	for value, index in values {
		if err := append_context_value(&environment, variables[index], value, allocator); !errs.ok(err) {
			return err
		}
		snapshot.environment = environment[:]
	}
	snapshot.environment = environment[:]
	if err := validate_description(
		{command = {"context"}, working_dir = snapshot.working_dir, environment = snapshot.environment},
		allocator,
	); !errs.ok(err) {
		return err
	}
	succeeded = true
	return {}
}

context_snapshot_destroy :: proc(snapshot: ^Context_Snapshot) {
	if snapshot == nil {
		return
	}
	allocator := snapshot.allocator
	environment_destroy(snapshot.environment, allocator)
	delete(snapshot.working_dir, allocator)
	snapshot^ = {}
}
