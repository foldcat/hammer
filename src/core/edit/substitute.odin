package edit

import address "../address"
import errs "../errs"
import rope "../rope"
import txn "../txn"

execute_substitution :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	program: ^Program,
	command: ^Command,
	dot: rope.Byte_Range,
	history: ^address.Regex_History,
	group: u64,
	allocator := context.allocator,
	cancelled: ^bool = nil,
) -> errs.Error {
	if dot.end - dot.start > MAX_MOVE_BYTES {
		return errs.newf(.Resource_Limit, "edit: substitution range exceeds %d bytes", MAX_MOVE_BYTES, allocator = allocator)
	}
	max_matches := command.count
	if command.global {
		max_matches = address.MAX_REGEX_MATCHES + 1
	}
	matches, find_err := address.regex_find_matches(
		&doc.tree,
		command_pattern(program, command^),
		dot,
		history,
		max_matches,
		allocator,
		cancelled,
	)
	if !errs.ok(find_err) {
		return find_err
	}
	defer delete(matches, allocator)
	if len(matches) < command.count {
		return errs.new(.NotFound, "edit: no substitution", allocator = allocator)
	}
	if command.global && len(matches) > address.MAX_REGEX_MATCHES {
		return errs.newf(.Resource_Limit, "edit: more than %d substitutions", address.MAX_REGEX_MATCHES, allocator = allocator)
	}
	selected := matches[command.count - 1:]
	if !command.global {
		selected = selected[:1]
	}

	source, read_err := rope.tree_read_all(&doc.tree, dot, allocator)
	if !errs.ok(read_err) {
		return read_err
	}
	defer delete(source, allocator)
	operations := make([dynamic]txn.Operation, allocator)
	replacements := make([dynamic][]byte, allocator)
	defer {
		for replacement in replacements {
			delete(replacement[:], allocator)
		}
		delete(replacements[:], allocator)
		delete(operations[:], allocator)
	}
	if reserve_err := reserve(&operations, len(selected)); reserve_err != .None {
		return errs.new(.Resource_Limit, "edit: could not reserve substitution operations", allocator = allocator)
	}
	if reserve_err := reserve(&replacements, len(selected)); reserve_err != .None {
		return errs.new(.Resource_Limit, "edit: could not reserve substitution text", allocator = allocator)
	}

	template := command_text(program, command^)
	total_replacement_bytes := 0
	for match in selected {
		if address.cancellation_requested(cancelled) {
			return errs.new(.Cancelled, "edit: substitution was cancelled", allocator = allocator)
		}
		replacement := make([dynamic]u8, allocator)
		for index := 0; index < len(template); {
			if template[index] == '&' {
				if err := append_capture(&replacement, source, dot, match.groups[0], &total_replacement_bytes, allocator); !errs.ok(err) {
					delete(replacement[:], allocator)
					return err
				}
				index += 1
				continue
			}
			if template[index] == '\\' && index + 1 < len(template) {
				next := template[index + 1]
				if next >= '1' && next <= '9' {
					group := int(next - '0')
					if err := append_capture(&replacement, source, dot, match.groups[group], &total_replacement_bytes, allocator); !errs.ok(err) {
						delete(replacement[:], allocator)
						return err
					}
				} else {
					if err := append_replacement_bytes(&replacement, template[index + 1:index + 2], &total_replacement_bytes, allocator); !errs.ok(err) {
						delete(replacement[:], allocator)
						return err
					}
				}
				index += 2
				continue
			}
			if err := append_replacement_bytes(&replacement, template[index:index + 1], &total_replacement_bytes, allocator); !errs.ok(err) {
				delete(replacement[:], allocator)
				return err
			}
			index += 1
		}
		owned, owned_err := make([]byte, len(replacement), allocator)
		if owned_err != .None {
			delete(replacement[:], allocator)
			return errs.new(.Resource_Limit, "edit: could not own substitution text", allocator = allocator)
		}
		copy(owned, replacement[:])
		delete(replacement[:], allocator)
		append(&replacements, owned)
		append(&operations, txn.Operation(txn.Replace{range = match.range, data = owned}))
	}

	new_total := rope.tree_byte_count(&doc.tree) + total_replacement_bytes
	for match in selected {
		new_total -= match.range.end - match.range.start
	}
	after := txn.Selection{anchor = min(dot.start, new_total), active = min(dot.end, new_total), affinity = .Right}
	return apply(doc, selection, operations[:], after, group, allocator)
}

append_capture :: proc(
	replacement: ^[dynamic]u8,
	source: []byte,
	dot: rope.Byte_Range,
	capture: rope.Byte_Range,
	total: ^int,
	allocator := context.allocator,
) -> errs.Error {
	if capture.start < 0 {
		return {}
	}
	if capture.start < dot.start || capture.end < capture.start || capture.end > dot.end {
		return errs.new(.Internal, "edit: capture is outside the substitution range", allocator = allocator)
	}
	return append_replacement_bytes(replacement, source[capture.start - dot.start:capture.end - dot.start], total, allocator)
}

append_replacement_bytes :: proc(
	replacement: ^[dynamic]u8,
	data: []byte,
	total: ^int,
	allocator := context.allocator,
) -> errs.Error {
	if len(data) > MAX_MOVE_BYTES - total^ {
		return errs.newf(.Resource_Limit, "edit: replacement output exceeds %d bytes", MAX_MOVE_BYTES, allocator = allocator)
	}
	if reserve_err := reserve(replacement, len(replacement) + len(data)); reserve_err != .None {
		return errs.new(.Resource_Limit, "edit: could not grow substitution text", allocator = allocator)
	}
	append(replacement, ..data)
	total^ += len(data)
	return {}
}
