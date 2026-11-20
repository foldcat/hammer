package command_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import command "hammer:core/command"

filter_definition :: proc(name, body: string, scope: command.Filter_Scope) -> command.Filter_Definition {
	return {
		name = name,
		engine = "engine",
		body = body,
		origin = "test",
		scope = scope,
		routing = .Replace_Selection,
	}
}

filter_sandbox :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "hammer-filter-*", context.allocator)
	testing.expectf(t, err == nil, "cannot create filter sandbox: %v", err)
	return path
}

filter_os_ok :: proc(t: ^testing.T, err: os.Error) {
	testing.expectf(t, err == nil, "unexpected OS error: %v", err)
}

filter_write :: proc(t: ^testing.T, path, text: string) {
	filter_os_ok(t, os.write_entire_file(path, text))
}

@(test)
test_filter_parse_register_lookup_and_enumerate :: proc(t: ^testing.T) {
	parsed, parse_err := command.filter_parse_definition(
		"# declarative metadata\nname: sort\nengine: engine\nrouting: output-window\nbody: $*IN.lines.sort\n",
		"memory.filter",
		.User,
		context.allocator,
	)
	expect_ok(t, parse_err)
	testing.expect(t, parsed.name == "sort" && parsed.routing == .Output_Window && parsed.origin == "memory.filter")

	registry: command.Filter_Registry
	expect_ok(t, command.filter_registry_init(&registry, {}, context.allocator))
	defer command.filter_registry_destroy(&registry)
	expect_ok(t, command.filter_registry_register(&registry, filter_definition("sort", "user-secret-body", .User)))
	expect_ok(t, command.filter_registry_register(&registry, filter_definition("sort", "project-secret-body", .Project)))
	expect_ok(t, command.filter_registry_register(&registry, filter_definition("sum", "session-secret-body", .Session)))
	expect_kind(t, command.filter_registry_register(&registry, filter_definition("sort", "duplicate", .Project)), .Conflict)
	found := command.filter_registry_find(&registry, "sort")
	testing.expect(t, found != nil && found.body == "project-secret-body" && found.engine_path == "")
	testing.expect(t, command.filter_registry_available_count(&registry) == 0)
	report, describe_err := command.filter_registry_describe(&registry, context.allocator)
	expect_ok(t, describe_err)
	defer delete(report, context.allocator)
	testing.expect(t, strings.contains(report, "3 named filter command(s); 0 engine(s) available"))
	testing.expect(t, strings.contains(report, "scope=project"))
	testing.expect(t, !strings.contains(report, "secret-body"))
	first_sort := strings.index(report, "sort  scope=user")
	second_sort := strings.index(report, "sort  scope=project")
	testing.expect(t, first_sort >= 0 && second_sort > first_sort)
	testing.expect(t, strings.index(report, "sort  scope=user") < strings.index(report, "sum  scope=session"))
}

@(test)
test_filter_parse_validation_and_capacity :: proc(t: ^testing.T) {
	invalid := []string{
		"name: bad name\nengine: engine\nrouting: discard\nbody: x\n",
		"name: good\nengine: bad/engine\nrouting: discard\nbody: x\n",
		"name: good\nengine: engine\nrouting: unknown\nbody: x\n",
		"name: good\nengine: engine\nrouting: discard\nbody:\n",
		"name: good\nengine: engine\nrouting: discard\n",
		"name: good\nname: duplicate\nengine: engine\nrouting: discard\nbody: x\n",
		"not a mapping\n",
	}
	for text in invalid {
		_, err := command.filter_parse_definition(text, "invalid.filter", .User, context.allocator)
		expect_kind(t, err, .Invalid_Input)
	}
	registry: command.Filter_Registry
	expect_ok(t, command.filter_registry_init(&registry, {}, context.allocator))
	defer command.filter_registry_destroy(&registry)
	for index in 0 ..< command.MAX_FILTER_COMMANDS {
		name := fmt.tprintf("command-%d", index)
		expect_ok(t, command.filter_registry_register(&registry, filter_definition(name, "x", .Session)))
	}
	expect_kind(t, command.filter_registry_register(&registry, filter_definition("overflow", "x", .Session)), .Resource_Limit)
}

@(test)
test_filter_discovery_scopes_availability_and_atomic_reload :: proc(t: ^testing.T) {
	root := filter_sandbox(t)
	defer delete(root, context.allocator)
	defer os.remove_all(root)
	commands := fmt.tprintf("%s/commands", root)
	project := fmt.tprintf("%s/project", root)
	bin := fmt.tprintf("%s/bin", root)
	filter_os_ok(t, os.make_directory_all(commands))
	filter_os_ok(t, os.make_directory_all(project))
	filter_os_ok(t, os.make_directory_all(bin))
	engine := fmt.tprintf("%s/engine", bin)
	filter_write(t, engine, "this file is data, not an invocation")
	filter_os_ok(t, os.chmod(engine, os.perm_number(0o755)))
	engine_info, engine_stat_err := os.stat(engine, context.allocator)
	filter_os_ok(t, engine_stat_err)
	defer os.file_info_delete(engine_info, context.allocator)
	testing.expectf(t, command.filter_engine_file(engine, context.allocator), "engine type=%v mode=%v", engine_info.type, engine_info.mode)
	marker := fmt.tprintf("%s/executed", root)
	filter_write(t, fmt.tprintf("%s/z.filter", commands), "name: zed\nengine: engine\nrouting: discard\nbody: x\n")
	filter_write(t, fmt.tprintf("%s/a.filter", commands), fmt.tprintf("name: sort\nengine: engine\nrouting: replace-selection\nbody: touch %s\n", marker))
	filter_write(t, fmt.tprintf("%s/ignored.txt", commands), "not a definition")
	filter_write(t, fmt.tprintf("%s/project.filter", project), "name: sort\nengine: missing\nrouting: output-window\nbody: project\n")

	registry: command.Filter_Registry
	expect_ok(t, command.filter_registry_init(&registry, {path = bin}, context.allocator))
	defer command.filter_registry_destroy(&registry)
	direct_path, direct_resolve_err := command.filter_engine_resolve(&registry, "engine")
	expect_ok(t, direct_resolve_err)
	defer delete(direct_path, context.allocator)
	testing.expectf(t, direct_path == engine, "direct resolved=%q expected=%q registry_path=%q", direct_path, engine, registry.path)
	expect_ok(t, command.filter_registry_load_directory(&registry, .User, commands))

	testing.expectf(t, registry.count == 2 && command.filter_registry_available_count(&registry) == 2, "count=%d available=%d", registry.count, command.filter_registry_available_count(&registry))
	found := command.filter_registry_find(&registry, "sort")
	resolved := "<nil>"
	if found != nil {
		resolved = found.engine_path
	}
	testing.expectf(t, found != nil && found.scope == .User && found.engine_path == engine, "resolved=%q expected=%q", resolved, engine)
	expect_ok(t, command.filter_registry_load_directory(&registry, .Project, project))
	testing.expect(t, registry.count == 3 && command.filter_registry_available_count(&registry) == 2)
	found = command.filter_registry_find(&registry, "sort")
	testing.expect(t, found != nil && found.scope == .Project && found.engine_path == "")
	report, describe_err := command.filter_registry_describe(&registry, context.allocator)
	expect_ok(t, describe_err)
	defer delete(report, context.allocator)
	testing.expect(t, strings.index(report, "a.filter") < strings.index(report, "z.filter"))
	testing.expect(t, strings.contains(report, "available=missing"))
	testing.expect(t, !os.exists(marker))

	filter_write(t, fmt.tprintf("%s/bad.filter", commands), "name: bad\nengine: engine\nrouting: invalid\nbody: x\n")
	expect_kind(t, command.filter_registry_load_directory(&registry, .User, commands), .Invalid_Input)
	testing.expect(t, registry.count == 3)
	found = command.filter_registry_find(&registry, "sort")
	testing.expect(t, found != nil && found.scope == .Project)
	expect_kind(t, command.filter_registry_load_directory(&registry, .User, fmt.tprintf("%s/missing", root)), .NotFound)

	filter_os_ok(t, os.remove(fmt.tprintf("%s/a.filter", commands)))
	filter_os_ok(t, os.remove(fmt.tprintf("%s/z.filter", commands)))
	filter_os_ok(t, os.remove(fmt.tprintf("%s/bad.filter", commands)))
	expect_ok(t, command.filter_registry_load_directory(&registry, .User, commands))
	testing.expect(t, registry.count == 1)
	found = command.filter_registry_find(&registry, "sort")
	testing.expect(t, found != nil && found.scope == .Project)
	testing.expect(t, !os.exists(marker))
	expect_ok(t, command.filter_registry_clear_scope(&registry, .Project))
	testing.expect(t, registry.count == 0 && command.filter_registry_find(&registry, "sort") == nil)
}
