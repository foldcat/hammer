package edit

import address "../address"
import errs "../errs"
import rope "../rope"
import txn "../txn"

// execute runs commands against successive intermediate documents. Mutations
// in the invocation share one undo group; a runtime error does not roll back
// commands that already succeeded, while parse errors happen before this call.
execute :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	program: ^Program,
	history: ^address.Regex_History,
	grouping_key: u64 = 0,
	allocator := context.allocator,
	cancelled: ^bool = nil,
) -> errs.Error {
	if doc == nil || selection == nil || program == nil {
		return errs.new(.Invalid_Input, "edit: nil document, selection, or program", allocator = allocator)
	}
	if !txn.selection_in_bounds(selection^, rope.tree_byte_count(&doc.tree)) {
		return errs.new(.Invalid_Input, "edit: selection is outside the document", allocator = allocator)
	}
	if err := validate_position(&doc.tree, selection.anchor, allocator); !errs.ok(err) {
		return err
	}
	if err := validate_position(&doc.tree, selection.active, allocator); !errs.ok(err) {
		return err
	}
	for command in program.commands {
		if command.text_offset < 0 || command.text_length < 0 ||
			command.text_offset > len(program.text) || command.text_length > len(program.text) - command.text_offset ||
			command.pattern_offset < 0 || command.pattern_length < 0 ||
			command.pattern_offset > len(program.text) || command.pattern_length > len(program.text) - command.pattern_offset {
			return errs.new(.Invalid_Input, "edit: command text is outside program storage", allocator = allocator)
		}
		if command.kind == .Substitute && (command.count <= 0 || command.count > address.MAX_REGEX_MATCHES) {
			return errs.new(.Invalid_Input, "edit: invalid substitution occurrence", allocator = allocator)
		}
	}

	group := grouping_key
	if group == 0 {
		group = doc.next_revision
		if group == 0 {
			group = 1
		}
	}
	if doc.current != 0 && doc.log[doc.current - 1].grouping_key == group {
		group += 1
		if group == 0 {
			group = 1
		}
	}

	for &command in program.commands {
		if address.cancellation_requested(cancelled) {
			return errs.new(.Cancelled, "edit: execution was cancelled", allocator = allocator)
		}
		previous_dot := selection_range(selection^)
		dot := previous_dot
		if command.has_address {
			evaluated, err := address.evaluate_with_history(&doc.tree, &command.expression, previous_dot, history, allocator, cancelled)
			if !errs.ok(err) {
				return err
			}
			dot = evaluated
		}

		switch command.kind {
		case .Set_Dot:
			set_selection(selection, dot.start, dot.end)
		case .Append, .Insert:
			text := command_text(program, command)
			position := dot.end if command.kind == .Append else dot.start
			operation := txn.Operation(txn.Insert{pos = position, data = text})
			after := txn.Selection{anchor = position, active = position + len(text), affinity = .Right}
			if err := apply(doc, selection, []txn.Operation{operation}, after, group, allocator); !errs.ok(err) {
				return err
			}
		case .Change:
			text := command_text(program, command)
			after := txn.Selection{anchor = dot.start, active = dot.start + len(text), affinity = .Right}
			if dot.start == dot.end && len(text) == 0 {
				selection^ = after
				continue
			}
			operation := txn.Operation(txn.Replace{range = dot, data = text})
			if err := apply(doc, selection, []txn.Operation{operation}, after, group, allocator); !errs.ok(err) {
				return err
			}
		case .Delete:
			set_selection(selection, dot.start, dot.start)
			if dot.start == dot.end {
				continue
			}
			operation := txn.Operation(txn.Delete{range = dot})
			if err := apply(doc, selection, []txn.Operation{operation}, selection^, group, allocator); !errs.ok(err) {
				return err
			}
		case .Substitute:
			if err := execute_substitution(doc, selection, program, &command, dot, history, group, allocator, cancelled); !errs.ok(err) {
				return err
			}
		case .Move, .Copy:
			destination, err := address.evaluate_with_history(&doc.tree, &command.destination, previous_dot, history, allocator, cancelled)
			if !errs.ok(err) {
				return err
			}
			length := dot.end - dot.start
			if length > MAX_MOVE_BYTES {
				return errs.newf(
					.Resource_Limit,
					"edit: move/copy range has %d bytes; budget is %d",
					length,
					MAX_MOVE_BYTES,
					allocator = allocator,
				)
			}
			if command.kind == .Move {
				if dot.start == destination.start && dot.end == destination.end {
					set_selection(selection, dot.start, dot.end)
					continue
				}
				if dot.end > destination.start && dot.start < destination.end {
					return errs.new(.Invalid_Input, "edit: move destination overlaps its source", allocator = allocator)
				}
			}
			if length == 0 {
				set_selection(selection, destination.end, destination.end)
				continue
			}
			text, read_err := rope.tree_read_all(&doc.tree, dot, allocator)
			if !errs.ok(read_err) {
				return read_err
			}
			defer delete(text, allocator)

			insert := txn.Operation(txn.Insert{pos = destination.end, data = text})
			if command.kind == .Copy {
				after := txn.Selection{anchor = destination.end, active = destination.end + length, affinity = .Right}
				if apply_err := apply(doc, selection, []txn.Operation{insert}, after, group, allocator); !errs.ok(apply_err) {
					return apply_err
				}
			} else {
				remove := txn.Operation(txn.Delete{range = dot})
				position := destination.end
				if dot.end <= destination.start {
					position -= length
				}
				after := txn.Selection{anchor = position, active = position + length, affinity = .Right}
				if apply_err := apply(doc, selection, []txn.Operation{insert, remove}, after, group, allocator); !errs.ok(apply_err) {
					return apply_err
				}
			}
		case:
			return errs.new(.Invalid_Input, "edit: invalid command kind", allocator = allocator)
		}
	}
	return {}
}

apply :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	operations: []txn.Operation,
	after: txn.Selection,
	group: u64,
	allocator := context.allocator,
) -> errs.Error {
	transaction := txn.Transaction{
		source = .Edit,
		base_revision = txn.doc_revision(doc),
		grouping_key = group,
		ops = operations,
		after_selection = after,
	}
	if err := txn.doc_apply(doc, &transaction, allocator); !errs.ok(err) {
		return err
	}
	selection^ = after
	return {}
}

selection_range :: proc(selection: txn.Selection) -> rope.Byte_Range {
	return {min(selection.anchor, selection.active), max(selection.anchor, selection.active)}
}

set_selection :: proc(selection: ^txn.Selection, start, end: int) {
	selection^ = {anchor = start, active = end, affinity = .Right}
}

validate_position :: proc(tree: ^rope.Tree, position: int, allocator := context.allocator) -> errs.Error {
	scalar, err := rope.tree_byte_to_scalar(tree, position, allocator)
	if !errs.ok(err) {
		return err
	}
	start, start_err := rope.tree_scalar_to_byte(tree, scalar, allocator)
	if !errs.ok(start_err) {
		return start_err
	}
	if start != position {
		return errs.newf(.Invalid_Input, "edit: byte offset %d splits a Unicode character", position, allocator = allocator)
	}
	return {}
}
