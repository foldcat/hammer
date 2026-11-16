// Package editing implements backend-free movement, selection, text-input,
// delayed-paste, indentation, newline indentation inheritance, and IME commit
// actions over transactional documents (M06.01–M06.12). Selections remain
// view-owned; text mutations go through the transaction engine.
package editing

import "core:math"
import "core:unicode"
import "core:unicode/utf8"

import errs "../errs"
import rope "../rope"
import txn "../txn"

// MAX_LINE_BYTES bounds the temporary copy used by grapheme and word motion.
// Longer lines return .Resource_Limit instead of allocating or scanning without
// a bound. Document boundaries and selection-all do not copy text.
MAX_LINE_BYTES :: 64 * 1024

Motion :: enum u8 {
	Grapheme_Left,
	Grapheme_Right,
	Word_Left,
	Word_Right,
	Line_Up,
	Line_Down,
	Line_Start,
	Line_End,
	Document_Start,
	Document_End,
}

Move :: struct {
	motion: Motion,
	extend: bool,
}

Select_All :: struct {}

Action :: union {
	Move,
	Select_All,
	Insert_Text,
	Commit_Text,
	Delete_Backward,
	Delete_Word_Backward,
	Delete_Forward,
}

// perform applies one semantic action to a document and view selection.
// Movement does not change text; insertion and deletion go through doc_apply.
perform :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	action: Action,
	allocator := context.allocator,
) -> errs.Error {
	if selection == nil {
		return errs.new(.Invalid_Input, "editing: nil selection", allocator = allocator)
	}
	switch a in action {
	case Move:
		return move(doc, selection, a.motion, a.extend, allocator)
	case Select_All:
		select_all(doc, selection)
		return {}
	case Insert_Text:
		return insert_text(doc, selection, a.text, a.grouping_key, allocator)
	case Commit_Text:
		return insert_committed_text(doc, selection, a.text, a.grouping_key, allocator)
	case Delete_Backward:
		return delete_at_selection(doc, selection, .Left, allocator)
	case Delete_Word_Backward:
		return delete_word_backward(doc, selection, allocator)
	case Delete_Forward:
		return delete_at_selection(doc, selection, .Right, allocator)
	}
	return {}
}

// selection_range returns the selected half-open byte range independent of
// selection direction.
selection_range :: proc(selection: txn.Selection) -> rope.Byte_Range {
	return {min(selection.anchor, selection.active), max(selection.anchor, selection.active)}
}

select_all :: proc(doc: ^txn.Doc, selection: ^txn.Selection) {
	selection.anchor = 0
	selection.active = rope.tree_byte_count(&doc.tree)
	selection.visual_column = 0
}

move :: proc(
	doc: ^txn.Doc,
	selection: ^txn.Selection,
	motion: Motion,
	extend: bool,
	allocator := context.allocator,
) -> errs.Error {
	if verr := validate_selection(doc, selection^, allocator); !errs.ok(verr) {
		return verr
	}

	origin := selection.active
	if !extend {
		#partial switch motion {
		case .Grapheme_Left, .Word_Left, .Line_Start, .Document_Start:
			origin = min(selection.anchor, selection.active)
		case .Grapheme_Right, .Word_Right, .Line_End, .Document_End:
			origin = max(selection.anchor, selection.active)
		case .Line_Up, .Line_Down:
		}
	}

	if !extend && selection.anchor != selection.active {
		#partial switch motion {
		case .Grapheme_Left, .Grapheme_Right, .Word_Left, .Word_Right:
			selection.anchor = origin
			selection.active = origin
			selection.visual_column = 0
			return {}
		case .Line_Up, .Line_Down, .Line_Start, .Line_End, .Document_Start, .Document_End:
		}
	}

	target := origin
	preferred_column := f64(0)
	switch motion {
	case .Grapheme_Left:
		target = origin
		if err := grapheme_step(&doc.tree, &target, .Left, allocator); !errs.ok(err) {
			return err
		}
	case .Grapheme_Right:
		target = origin
		if err := grapheme_step(&doc.tree, &target, .Right, allocator); !errs.ok(err) {
			return err
		}
	case .Word_Left:
		err: errs.Error
		target, err = word_left(&doc.tree, origin, allocator)
		if !errs.ok(err) {
			return err
		}
	case .Word_Right:
		err: errs.Error
		target, err = word_right(&doc.tree, origin, allocator)
		if !errs.ok(err) {
			return err
		}
	case .Line_Up, .Line_Down:
		direction := Step_Direction.Left
		if motion == .Line_Down {
			direction = .Right
		}
		err: errs.Error
		target, preferred_column, err = vertical_step(
			&doc.tree,
			origin,
			selection.visual_column,
			direction,
			allocator,
		)
		if !errs.ok(err) {
			return err
		}
	case .Line_Start, .Line_End:
		err: errs.Error
		target, err = line_boundary(&doc.tree, origin, motion == .Line_End, allocator)
		if !errs.ok(err) {
			return err
		}
	case .Document_Start:
		target = 0
	case .Document_End:
		target = rope.tree_byte_count(&doc.tree)
	}

	if !extend {
		selection.anchor = target
	}
	selection.active = target
	selection.visual_column = preferred_column
	return {}
}

validate_selection :: proc(doc: ^txn.Doc, selection: txn.Selection, allocator := context.allocator) -> errs.Error {
	total := rope.tree_byte_count(&doc.tree)
	if !txn.selection_in_bounds(selection, total) {
		return errs.newf(
			.Invalid_Input,
			"editing: selection [%v, %v] outside [0, %v]",
			selection.anchor,
			selection.active,
			total,
			allocator = allocator,
		)
	}
	if selection.affinity != .Left && selection.affinity != .Right {
		return errs.new(.Invalid_Input, "editing: invalid selection affinity", allocator = allocator)
	}
	if selection.visual_column < 0 ||
		math.is_nan(selection.visual_column) ||
		math.is_inf(selection.visual_column) ||
		selection.visual_column != math.floor(selection.visual_column) {
		return errs.new(.Invalid_Input, "editing: invalid preferred visual column", allocator = allocator)
	}
	return {}
}

Step_Direction :: enum u8 {
	Left,
	Right,
}

Line :: struct {
	index: rope.Line_Index,
	start: int,
	end:   int,
	data:  []byte, // owned by the caller; empty for an empty line
}

read_line_at :: proc(tree: ^rope.Tree, offset: int, allocator := context.allocator) -> (Line, errs.Error) {
	index, err := rope.tree_byte_to_line(tree, offset, allocator)
	if !errs.ok(err) {
		return {}, err
	}
	return read_line(tree, index, allocator)
}

read_line :: proc(tree: ^rope.Tree, index: rope.Line_Index, allocator := context.allocator) -> (Line, errs.Error) {
	start, start_err := rope.tree_line_start(tree, index, allocator)
	if !errs.ok(start_err) {
		return {}, start_err
	}
	after_break, end_err := rope.tree_line_end(tree, index, allocator)
	if !errs.ok(end_err) {
		return {}, end_err
	}

	end := after_break
	if after_break > start {
		tail_start := max(start, after_break - 2)
		tail: [2]u8
		n, read_err := rope.tree_read(
			tree,
			{tail_start, after_break},
			tail[:after_break - tail_start],
			allocator,
		)
		if !errs.ok(read_err) {
			return {}, read_err
		}
		if n > 0 && tail[n - 1] == '\n' {
			end -= 1
			if n > 1 && tail[n - 2] == '\r' {
				end -= 1
			}
		} else if n > 0 && tail[n - 1] == '\r' {
			end -= 1
		}
	}
	if end - start > MAX_LINE_BYTES {
		return {}, errs.newf(
			.Resource_Limit,
			"editing: line %v has %v bytes; movement budget is %v",
			index,
			end - start,
			MAX_LINE_BYTES,
			allocator = allocator,
		)
	}

	data: []byte
	if end > start {
		read_err: errs.Error
		data, read_err = rope.tree_read_all(tree, {start, end}, allocator)
		if !errs.ok(read_err) {
			return {}, read_err
		}
	}
	return Line{index = index, start = start, end = end, data = data}, {}
}

validate_line_offset :: proc(line: Line, offset: int, allocator := context.allocator) -> errs.Error {
	if offset < line.start || offset > line.end {
		return errs.newf(
			.Invalid_Input,
			"editing: byte offset %v is not a caret position on line %v",
			offset,
			line.index,
			allocator = allocator,
		)
	}
	return {}
}

grapheme_step :: proc(
	tree: ^rope.Tree,
	offset: ^int,
	direction: Step_Direction,
	allocator := context.allocator,
) -> errs.Error {
	line, err := read_line_at(tree, offset^, allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(line.data, allocator)
	if verr := validate_line_offset(line, offset^, allocator); !errs.ok(verr) {
		return verr
	}

	if direction == .Left && offset^ == line.start {
		if line.index == 0 {
			return {}
		}
		previous, previous_err := read_line(tree, line.index - 1, allocator)
		if !errs.ok(previous_err) {
			return previous_err
		}
		defer delete(previous.data, allocator)
		offset^ = previous.end
		return {}
	}
	if direction == .Right && offset^ == line.end {
		if int(line.index) + 1 >= rope.tree_line_count(tree) {
			return {}
		}
		next_start, start_err := rope.tree_line_start(tree, line.index + 1, allocator)
		if !errs.ok(start_err) {
			return start_err
		}
		offset^ = next_start
		return {}
	}

	it := utf8.decode_grapheme_iterator_make(string(line.data))
	previous_start := line.start
	for text, grapheme in utf8.decode_grapheme_iterate(&it) {
		start := line.start + grapheme.byte_index
		end := start + len(text)
		if offset^ > start && offset^ < end {
			return errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
		}
		if direction == .Right && offset^ == start {
			offset^ = end
			return {}
		}
		if direction == .Left {
			if offset^ == start {
				offset^ = previous_start
				return {}
			}
			if offset^ == end {
				offset^ = start
				return {}
			}
		}
		previous_start = start
	}
	if offset^ != line.end {
		return errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
	}
	return {}
}

line_boundary :: proc(
	tree: ^rope.Tree,
	offset: int,
	end: bool,
	allocator := context.allocator,
) -> (int, errs.Error) {
	line, err := read_line_at(tree, offset, allocator)
	if !errs.ok(err) {
		return 0, err
	}
	defer delete(line.data, allocator)
	if verr := validate_line_offset(line, offset, allocator); !errs.ok(verr) {
		return 0, verr
	}
	return line.end if end else line.start, {}
}

vertical_step :: proc(
	tree: ^rope.Tree,
	offset: int,
	preferred: f64,
	direction: Step_Direction,
	allocator := context.allocator,
) -> (int, f64, errs.Error) {
	line, err := read_line_at(tree, offset, allocator)
	if !errs.ok(err) {
		return 0, 0, err
	}
	defer delete(line.data, allocator)
	if verr := validate_line_offset(line, offset, allocator); !errs.ok(verr) {
		return 0, 0, verr
	}
	column, column_err := grapheme_column(line, offset, allocator)
	if !errs.ok(column_err) {
		return 0, 0, column_err
	}
	preferred_column := preferred
	if preferred_column == 0 {
		preferred_column = f64(column)
	}

	target_index := int(line.index) - 1
	if direction == .Right {
		target_index = int(line.index) + 1
	}
	if target_index < 0 || target_index >= rope.tree_line_count(tree) {
		return offset, preferred_column, {}
	}
	target_line, target_err := read_line(tree, rope.Line_Index(target_index), allocator)
	if !errs.ok(target_err) {
		return 0, 0, target_err
	}
	defer delete(target_line.data, allocator)
	target, target_column_err := byte_at_grapheme_column(target_line, preferred_column, allocator)
	if !errs.ok(target_column_err) {
		return 0, 0, target_column_err
	}
	return target, preferred_column, {}
}

grapheme_column :: proc(line: Line, offset: int, allocator := context.allocator) -> (int, errs.Error) {
	it := utf8.decode_grapheme_iterator_make(string(line.data))
	column := 0
	for text, grapheme in utf8.decode_grapheme_iterate(&it) {
		start := line.start + grapheme.byte_index
		end := start + len(text)
		if offset == start {
			return column, {}
		}
		if offset == end {
			return column + 1, {}
		}
		if offset > start && offset < end {
			return 0, errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
		}
		column += 1
	}
	if offset == line.end {
		return column, {}
	}
	return 0, errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
}

byte_at_grapheme_column :: proc(line: Line, column: f64, allocator := context.allocator) -> (int, errs.Error) {
	it := utf8.decode_grapheme_iterator_make(string(line.data))
	index := 0
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if column == f64(index) {
			return line.start + grapheme.byte_index, {}
		}
		index += 1
	}
	return line.end, {}
}

is_word_grapheme :: proc(text: string) -> bool {
	r, _ := utf8.decode_rune_in_string(text)
	return r == '_' || unicode.is_letter(r) || unicode.is_number(r)
}

word_left :: proc(tree: ^rope.Tree, offset: int, allocator := context.allocator) -> (int, errs.Error) {
	line, err := read_line_at(tree, offset, allocator)
	if !errs.ok(err) {
		return 0, err
	}
	first_line := true

	for {
		limit := line.end
		if first_line {
			limit = offset
		}
		candidate, scan_err := last_word_start_before(line, limit, allocator)
		delete(line.data, allocator)
		if !errs.ok(scan_err) {
			return 0, scan_err
		}
		if candidate >= 0 {
			return candidate, {}
		}
		if line.index == 0 {
			return 0, {}
		}
		line, err = read_line(tree, line.index - 1, allocator)
		if !errs.ok(err) {
			return 0, err
		}
		first_line = false
	}
}

last_word_start_before :: proc(line: Line, limit: int, allocator := context.allocator) -> (int, errs.Error) {
	if limit < line.start || limit > line.end {
		return 0, errs.new(.Invalid_Input, "editing: caret is outside the line", allocator = allocator)
	}
	candidate := -1
	in_word := false
	it := utf8.decode_grapheme_iterator_make(string(line.data))
	for text, grapheme in utf8.decode_grapheme_iterate(&it) {
		start := line.start + grapheme.byte_index
		end := start + len(text)
		if start >= limit {
			break
		}
		if limit > start && limit < end {
			return 0, errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
		}
		word := is_word_grapheme(text)
		if word && !in_word {
			candidate = start
		}
		in_word = word
	}
	return candidate, {}
}

word_right :: proc(tree: ^rope.Tree, offset: int, allocator := context.allocator) -> (int, errs.Error) {
	line, err := read_line_at(tree, offset, allocator)
	if !errs.ok(err) {
		return 0, err
	}
	first_line := true
	skipping_word := false

	for {
		limit := line.end
		if first_line {
			limit = offset
		}
		target, skipping, scan_err := first_word_start_after(line, limit, first_line, skipping_word, allocator)
		skipping_word = skipping
		delete(line.data, allocator)
		if !errs.ok(scan_err) {
			return 0, scan_err
		}
		if target >= 0 {
			return target, {}
		}
		if int(line.index) + 1 >= rope.tree_line_count(tree) {
			return rope.tree_byte_count(tree), {}
		}
		line, err = read_line(tree, line.index + 1, allocator)
		if !errs.ok(err) {
			return 0, err
		}
		first_line = false
		skipping_word = false
	}
}

first_word_start_after :: proc(
	line: Line,
	offset: int,
	validate_offset: bool,
	skipping_word: bool,
	allocator := context.allocator,
) -> (int, bool, errs.Error) {
	if validate_offset && (offset < line.start || offset > line.end) {
		return 0, false, errs.new(.Invalid_Input, "editing: caret is outside the line", allocator = allocator)
	}
	skip := skipping_word
	it := utf8.decode_grapheme_iterator_make(string(line.data))
	for text, grapheme in utf8.decode_grapheme_iterate(&it) {
		start := line.start + grapheme.byte_index
		end := start + len(text)
		if validate_offset {
			if offset > start && offset < end {
				return 0, false, errs.new(.Invalid_Input, "editing: caret splits a grapheme", allocator = allocator)
			}
			if start < offset {
				continue
			}
		}
		word := is_word_grapheme(text)
		if start == offset && validate_offset {
			skip = word
		}
		if word {
			if skip {
				continue
			}
			return start, skip, {}
		}
		skip = false
	}
	return -1, skip, {}
}
