package main

import "core:log"
import "core:os"

import command "core/command"
import errs "core/errs"

editor_filter_load_user :: proc() -> errs.Error {
	directory, path_err := command.filter_user_directory(context.temp_allocator)
	if !errs.ok(path_err) {
		return path_err
	}
	defer delete(directory, context.temp_allocator)
	if directory == "" || !os.exists(directory) {
		return command.filter_registry_clear_scope(&editor.filters, .User)
	}
	if err := command.filter_registry_load_directory(&editor.filters, .User, directory); !errs.ok(err) {
		return err
	}
	log.infof("filter: loaded user definitions from %s", directory)
	return {}
}

editor_filter_load_project :: proc() -> errs.Error {
	root, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		return errs.newf(.IO, "filter: cannot determine project root: %v", cwd_err, allocator = permanent())
	}
	defer delete(root, context.temp_allocator)
	directory, path_err := command.filter_project_directory(root, context.temp_allocator)
	if !errs.ok(path_err) {
		return path_err
	}
	defer delete(directory, context.temp_allocator)
	if !os.exists(directory) {
		return errs.newf(.NotFound, "filter: no project command directory at %s", directory, allocator = permanent())
	}
	log.warnf("filter: explicitly trusting project definitions from %s", directory)
	return command.filter_registry_load_directory(&editor.filters, .Project, directory)
}

editor_filter_show :: proc() -> errs.Error {
	if editor.workspace.column_count == 0 {
		return errs.new(.NotFound, "filter: no column is available for command discovery", allocator = permanent())
	}
	report, describe_err := command.filter_registry_describe(&editor.filters, context.temp_allocator)
	if !errs.ok(describe_err) {
		return describe_err
	}
	defer delete(report, context.temp_allocator)
	buffer, alloc_err := editor_alloc_buffer_content("", transmute([]byte)report, .Commands)
	if !errs.ok(alloc_err) {
		return alloc_err
	}
	column_id := editor.workspace.columns[editor.workspace.column_count - 1].id
	item, open_err := editor_open_buffer_in_column(buffer, column_id)
	if !errs.ok(open_err) {
		return open_err
	}
	log.infof(
		"filter: listed %d definitions (%d engines available) in window %d",
		editor.filters.count,
		command.filter_registry_available_count(&editor.filters),
		u64(item.window_id),
	)
	return {}
}

editor_command_cmds :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	switch invocation.argument {
	case "":
	case "user":
		if err := editor_filter_load_user(); !errs.ok(err) {
			return err
		}
	case "project":
		if err := editor_filter_load_project(); !errs.ok(err) {
			return err
		}
	case:
		return errs.new(.Invalid_Input, "filter: Cmds accepts no argument, 'user', or 'project'", allocator = permanent())
	}
	return editor_filter_show()
}
