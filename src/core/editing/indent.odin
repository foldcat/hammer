package editing

import errs "../errs"
import rope "../rope"
import txn "../txn"

DEFAULT_INDENT_WIDTH :: 4
MAX_INDENT_WIDTH :: 32
MAX_INDENT_LINES :: 4096

Indent_Style :: enum u8 {
	Tabs,
	Spaces,
}

// Indent_Settings are the effective settings for the target buffer. Callers
// resolve defaults, EditorConfig, and buffer overrides before invoking indent.
// A zero width selects DEFAULT_INDENT_WIDTH.
Indent_Settings :: struct {
	style: Indent_Style,
	width: int,
}

Indent_Direction :: enum u8 {
	Indent,
	Outdent,
}

// indent applies one indentation action as one transaction. A collapsed Indent
// inserts at the caret; every other action covers whole selected lines. If a
// nonempty selection ends at a line start, that final line is excluded.
indent :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	direction: Indent_Direction,
	settings: Indent_Settings,
	allocator := context.allocator,
) -> errs.Error {
	if doc == nil || selection == nil {
		return errs.new(.Invalid_Input, "editing: indentation target is not available", allocator = allocator)
	}
	if direction != .Indent && direction != .Outdent {
		return errs.new(.Invalid_Input, "editing: invalid indentation direction", allocator = allocator)
	}
	width := settings.width
	if width == 0 {
		width = DEFAULT_INDENT_WIDTH
	}
	if width < 0 || width > MAX_INDENT_WIDTH ||
		(settings.style != .Tabs && settings.style != .Spaces) {
		return errs.new(.Invalid_Input, "editing: invalid indentation settings", allocator = allocator)
	}
	if err := validate_edit_selection(doc, selection^, allocator); !errs.ok(err) {
		return err
	}

	if direction == .Indent && selection.anchor == selection.active {
		unit: [MAX_INDENT_WIDTH]u8
		unit_len := width
		if settings.style == .Tabs {
			unit[0] = '\t'
			unit_len = 1
		} else {
			for &b in unit[:width] {
				b = ' '
			}
		}
		after := txn.Selection {
			anchor = selection.active + unit_len,
			active = selection.active + unit_len,
			affinity = .Left,
		}
		ops := []txn.Operation{txn.Insert{pos = selection.active, data = unit[:unit_len]}}
		return indent_apply(doc, selection, ops, after, allocator)
	}

	range := selection_range(selection^)
	first_line, line_err := rope.tree_byte_to_line(&doc.tree, range.start, allocator)
	if !errs.ok(line_err) {
		return line_err
	}
	last_line, last_err := rope.tree_byte_to_line(&doc.tree, range.end, allocator)
	if !errs.ok(last_err) {
		return last_err
	}
	if range.end > range.start {
		last_start, start_err := rope.tree_line_start(&doc.tree, last_line, allocator)
		if !errs.ok(start_err) {
			return start_err
		}
		if range.end == last_start {
			last_line -= 1
		}
	}
	line_count := int(last_line - first_line) + 1
	if line_count > MAX_INDENT_LINES {
		return errs.newf(
			.Resource_Limit,
			"editing: indentation covers %d lines; limit is %d",
			line_count,
			MAX_INDENT_LINES,
			allocator = allocator,
		)
	}

	operations := make([dynamic]txn.Operation, allocator)
	defer delete(operations)
	if reserve_err := reserve(&operations, line_count); reserve_err != .None {
		return errs.newf(
			.Resource_Limit,
			"editing: reserving indentation operations failed: %v",
			reserve_err,
			allocator = allocator,
		)
	}

	unit: [MAX_INDENT_WIDTH]u8
	unit_len := width
	if settings.style == .Tabs {
		unit[0] = '\t'
		unit_len = 1
	} else {
		for &b in unit[:width] {
			b = ' '
		}
	}
	total := rope.tree_byte_count(&doc.tree)
	for line := first_line; line <= last_line; line += 1 {
		start, start_err := rope.tree_line_start(&doc.tree, line, allocator)
		if !errs.ok(start_err) {
			return start_err
		}
		if direction == .Indent {
			append(&operations, txn.Insert{pos = start, data = unit[:unit_len]})
			continue
		}

		read_len := min(width, total - start)
		if read_len == 0 {
			continue
		}
		leading: [MAX_INDENT_WIDTH]u8
		n, read_err := rope.tree_read(&doc.tree, {start, start + read_len}, leading[:read_len], allocator)
		if !errs.ok(read_err) {
			return read_err
		}
		if n == 0 {
			continue
		}
		remove := 0
		if leading[0] == '\t' {
			remove = 1
		} else if leading[0] == ' ' {
			for remove < n && leading[remove] == ' ' {
				remove += 1
			}
		}
		if remove > 0 {
			append(&operations, txn.Delete{range = {start, start + remove}})
		}
	}

	if len(operations) == 0 {
		return {}
	}
	after := txn.Selection {
		anchor = indent_adjusted_offset(selection.anchor, operations[:]),
		active = indent_adjusted_offset(selection.active, operations[:]),
		affinity = selection.affinity,
	}
	return indent_apply(doc, selection, operations[:], after, allocator)
}

// indent_adjusted_offset maps an original selection endpoint through ascending,
// nonoverlapping line edits. An insertion exactly at an endpoint stays to its
// right, keeping the original range selected rather than absorbing a final
// excluded line's indentation.
indent_adjusted_offset :: proc(offset: int, operations: []txn.Operation) -> int {
	adjusted := offset
	for operation in operations {
		switch op in operation {
		case txn.Insert:
			if op.pos >= offset {
				break
			}
			adjusted += len(op.data)
		case txn.Delete:
			if op.range.start >= offset {
				break
			}
			if offset >= op.range.end {
				adjusted -= op.range.end - op.range.start
			} else {
				adjusted -= offset - op.range.start
			}
		case txn.Replace:
			unreachable()
		}
	}
	return adjusted
}

indent_apply :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	operations: []txn.Operation,
	after: txn.Selection,
	allocator := context.allocator,
) -> errs.Error {
	transaction := txn.Transaction {
		source = .Indent,
		base_revision = txn.doc_revision(doc),
		ops = operations,
		after_selection = after,
	}
	if err := txn.doc_apply(doc, &transaction, allocator); !errs.ok(err) {
		return err
	}
	selection^ = after
	return {}
}
