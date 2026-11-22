package main

import "core:fmt"
import "core:log"

import address "core/address"
import command "core/command"
import editing "core/editing"
import errs "core/errs"
import process "core/process"
import txn "core/txn"

editor_command_raku :: proc(cmd_context: ^command.Context, invocation: command.Invocation) -> errs.Error {
	target := editor_command_source_target(cmd_context.source)
	body := editor_target_body(target)
	if body.item == nil || body.selection == nil {
		return errs.new(.NotFound, "regex: Raku requires a source window body", allocator = permanent())
	}
	buffer := editor_buffer_for_view(body.item)
	if buffer == nil {
		return errs.new(.Internal, "regex: source window has no buffer", allocator = permanent())
	}
	expression, parse_err := address.parse(invocation.argument, context.temp_allocator)
	if !errs.ok(parse_err) {
		return parse_err
	}
	root := expression.nodes[expression.root]
	if expression.operation_count != 1 || root.kind != .Simple || root.operation_count != 1 {
		return errs.new(.Invalid_Input, "regex: Raku accepts exactly one /pattern/ expression", allocator = permanent())
	}
	operation := expression.operations[root.first_operation]
	if operation.kind != .Regex || operation.direction != .Forward || operation.origin != .Absolute {
		return errs.new(.Invalid_Input, "regex: Raku accepts exactly one forward /pattern/ expression", allocator = permanent())
	}

	dot := editing.selection_range(body.selection^)
	engine_path, resolve_err := command.filter_engine_resolve(&editor.filters, "raku")
	if !errs.ok(resolve_err) {
		return resolve_err
	}
	defer delete(engine_path, context.temp_allocator)
	if engine_path == "" {
		match, native_err := address.evaluate_with_history(&buffer.doc.tree, &expression, dot, &buffer.regex_history, context.temp_allocator)
		if !errs.ok(native_err) {
			return native_err
		}
		body.selection^ = txn.Selection{anchor = match.start, active = match.end, affinity = .Right}
		editor_reveal_caret(body.item)
		editor_finish_history_jump(body.item)
		log.infof("regex: native fallback window=%d buffer=%d range=%d,%d", u64(body.window_id), u64(buffer.id), match.start, match.end)
		return {}
	}

	pattern := string(expression.pattern_bytes[operation.pattern_offset:operation.pattern_offset + operation.pattern_length])
	if pattern == "" {
		if buffer.regex_history.pattern_length <= 0 || buffer.regex_history.pattern_length > len(buffer.regex_history.pattern_bytes) {
			return errs.new(.Invalid_Input, "regex: empty regular expression has no previous pattern", allocator = permanent())
		}
		pattern = string(buffer.regex_history.pattern_bytes[:buffer.regex_history.pattern_length])
	}
	argv, argv_err := command.raku_regex_command(engine_path, pattern, dot.end, context.temp_allocator)
	if !errs.ok(argv_err) {
		return argv_err
	}
	defer command.raku_regex_command_destroy(argv, context.temp_allocator)
	snapshot: process.Context_Snapshot
	if snapshot_err := process.context_snapshot_init(&snapshot, editor_filter_context_description(cmd_context.source), context.temp_allocator); !errs.ok(snapshot_err) {
		return snapshot_err
	}
	defer process.context_snapshot_destroy(&snapshot)

	line := fmt.aprintf("%s -e <external-regex> %s", engine_path, invocation.argument, allocator = context.temp_allocator)
	if line == "" {
		return errs.new(.Resource_Limit, "regex: cannot format external search echo", allocator = permanent())
	}
	defer delete(line, context.temp_allocator)
	log.infof("regex: echo %q", invocation.argument)
	editor_report(editor_append_error(line))
	id, start_err := process.job_start_regex_search(
		&editor.jobs,
		{command = argv, working_dir = snapshot.working_dir, environment = snapshot.environment},
		&buffer.doc,
		body.selection^,
		u64(buffer.id),
		buffer.generation,
		u64(body.window_id),
	)
	if !errs.ok(start_err) {
		return start_err
	}
	copy(buffer.regex_history.pattern_bytes[:], pattern)
	buffer.regex_history.pattern_length = len(pattern)
	log.infof("regex: external search started id=%d window=%d buffer=%d", u64(id), u64(body.window_id), u64(buffer.id))
	return {}
}
