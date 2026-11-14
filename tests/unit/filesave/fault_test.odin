package filesave_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

import errs "hammer:core/errs"
import fileload "hammer:core/fileload"
import filesave "hammer:core/filesave"

Fault_State :: struct {
	write_error_at: int,
	max_write:      int,
	zero_write:     bool,
	capture_calls:  int,
	fail_capture_at: int,
}

Fault_Case :: struct {
	name:    string,
	install: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State),
}

fault_error :: proc() -> os.Error {
	return os.General_Error.Broken_Pipe
}

fault_create_temp :: proc(data: rawptr, dir, pattern: string) -> (^os.File, os.Error) {
	return nil, fault_error()
}

fault_write :: proc(data: rawptr, file: ^os.File, bytes: []byte) -> (int, os.Error) {
	state := (^Fault_State)(data)
	if state.zero_write {
		return 0, nil
	}
	if state.write_error_at >= 0 && state.max_write == 0 {
		return 0, fault_error()
	}
	n := len(bytes)
	if state.max_write > 0 {
		n = min(n, state.max_write)
	}
	return os.write(file, bytes[:n])
}

fault_sync :: proc(data: rawptr, file: ^os.File) -> os.Error {
	return fault_error()
}

fault_chmod :: proc(data: rawptr, file: ^os.File, mode: os.Permissions) -> os.Error {
	return fault_error()
}

fault_close :: proc(data: rawptr, file: ^os.File) -> os.Error {
	os.close(file)
	return fault_error()
}

fault_link :: proc(data: rawptr, old_path, new_path: string) -> os.Error {
	return fault_error()
}

fault_rename :: proc(data: rawptr, old_path, new_path: string) -> os.Error {
	return fault_error()
}

fault_remove :: proc(data: rawptr, path: string) -> os.Error {
	return fault_error()
}

fault_capture :: proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (fileload.Capture, errs.Error) {
	state := (^Fault_State)(data)
	state.capture_calls += 1
	if state.capture_calls == state.fail_capture_at {
		return {}, errs.newf(.IO, "injected capture failure", allocator = allocator)
	}
	return fileload.capture_file(path, allocator)
}

install_create_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	hooks.create_temp = fault_create_temp
}

install_write_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.write_error_at = 0
	hooks.write = fault_write
}

install_zero_write :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.zero_write = true
	hooks.write = fault_write
}

install_sync_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	hooks.sync = fault_sync
}

install_chmod_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	hooks.chmod = fault_chmod
}

install_close_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	hooks.close = fault_close
}

install_rename_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	hooks.rename = fault_rename
}

install_initial_capture_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.fail_capture_at = 1
	hooks.capture = fault_capture
}

install_recheck_capture_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.fail_capture_at = 2
	hooks.capture = fault_capture
}

install_final_capture_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.fail_capture_at = 3
	hooks.capture = fault_capture
}

install_new_final_capture_failure :: proc(hooks: ^filesave.Operation_Hooks, state: ^Fault_State) {
	state.fail_capture_at = 1
	hooks.capture = fault_capture
}

existing_fault_options :: proc(loaded: ^fileload.Loaded, hooks: ^filesave.Operation_Hooks) -> filesave.Options {
	return filesave.Options{disk_check = .Unchanged, expected = loaded.capture, operations = hooks}
}

@(test)
test_prepublication_fault_matrix_preserves_original_and_cleans_temp :: proc(t: ^testing.T) {
	cases := []Fault_Case {
		{name = "create", install = install_create_failure},
		{name = "write", install = install_write_failure},
		{name = "zero-write", install = install_zero_write},
		{name = "sync", install = install_sync_failure},
		{name = "chmod", install = install_chmod_failure},
		{name = "close", install = install_close_failure},
		{name = "rename", install = install_rename_failure},
		{name = "initial-capture", install = install_initial_capture_failure},
		{name = "recheck-capture", install = install_recheck_capture_failure},
	}
	for c in cases {
		dir := sandbox(t)
		if dir == "" {return}
		defer os.remove_all(dir)
		path := fmt.tprintf("%s/original.txt", dir)
		write_fixture(t, path, "original")
		loaded: fileload.Loaded
		if !load_fixture(t, &loaded, path) {return}
		fixture: Tree_Fixture
		fixture_init(t, &fixture, "replacement")
		state := Fault_State{write_error_at = -1}
		hooks := filesave.Operation_Hooks{data = &state}
		c.install(&hooks, &state)
		result, err := filesave.save_tree(
			{tree = &fixture.tree, root = fixture.tree.root, revision = 19},
			path,
			utf8_metadata(),
			existing_fault_options(&loaded, &hooks),
			context.allocator,
		)
		if err.kind != .IO {
			testing.expectf(t, false, "%s fault returned %v instead of IO", c.name, err.kind)
		}
		owned_err := err
		errs.destroy(&owned_err)
		testing.expectf(t, !result.replaced, "%s fault marked destination replaced", c.name)
		testing.expectf(t, result.capture.stamp.size == 0, "%s fault returned a checkpoint", c.name)
		data := read_fixture(t, path)
		testing.expectf(t, string(data) == "original", "%s fault changed destination to %q", c.name, string(data))
		delete(data)
		expect_only_one_entry(t, dir)
		fileload.loaded_destroy(&loaded)
		fixture_destroy(&fixture)
	}
}

@(test)
test_partial_writes_are_completed_not_treated_as_success_early :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/partial.txt", dir)
	write_fixture(t, path, "old")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	defer fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "every partial byte survives")
	defer fixture_destroy(&fixture)
	state := Fault_State{write_error_at = -1, max_write = 1}
	hooks := filesave.Operation_Hooks{data = &state, write = fault_write}
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		existing_fault_options(&loaded, &hooks),
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	testing.expect(t, result.replaced)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "every partial byte survives")
	expect_only_one_entry(t, dir)
}

@(test)
test_new_file_link_fault_does_not_publish :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/new.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	hooks := filesave.Operation_Hooks{link = fault_link}
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{operations = &hooks},
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, !result.replaced)
	testing.expect(t, !os.exists(path))
	expect_only_one_entry(t, dir, 0)
}

@(test)
test_post_replace_capture_fault_reports_changed_destination :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/replaced.txt", dir)
	write_fixture(t, path, "old")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	defer fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "published")
	defer fixture_destroy(&fixture)
	state := Fault_State{write_error_at = -1}
	hooks := filesave.Operation_Hooks{data = &state}
	install_final_capture_failure(&hooks, &state)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root, revision = 22},
		path,
		utf8_metadata(),
		existing_fault_options(&loaded, &hooks),
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, result.replaced)
	testing.expect(t, result.revision == 22)
	testing.expect(t, result.capture.stamp.size == 0)
	testing.expect(t, state.capture_calls == 3)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "published")
	expect_only_one_entry(t, dir)
}

@(test)
test_post_new_file_capture_fault_reports_changed_destination :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/new.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "published")
	defer fixture_destroy(&fixture)
	state := Fault_State{write_error_at = -1}
	hooks := filesave.Operation_Hooks{data = &state}
	install_new_final_capture_failure(&hooks, &state)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{operations = &hooks},
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, result.replaced)
	testing.expect(t, result.capture.stamp.size == 0)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "published")
	expect_only_one_entry(t, dir)
}

@(test)
test_post_new_file_cleanup_fault_reports_changed_destination :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/new.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "published")
	defer fixture_destroy(&fixture)
	hooks := filesave.Operation_Hooks{remove = fault_remove}
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{operations = &hooks},
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, result.replaced)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "published")
	expect_only_one_entry(t, dir, 2)
}
