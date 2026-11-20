package tag

import "core:strings"

import editing "../editing"
import errs "../errs"
import rope "../rope"
import txn "../txn"

MAX_GENERATED_BYTES :: 4096

State :: struct {
	doc:            txn.Doc,
	selection:      txn.Selection,
	generated_end:  int,
	// filepath_end is the byte offset of the end of the leftmost mutable token
	// (the window filepath/name). The generated commands between filepath_end
	// and generated_end are immutable; the filepath and the user suffix are not.
	filepath_end:   int,
	// lock_commands gates the generated-commands region. Blank (untitled) file
	// buffers set this false so the whole tag is editable.
	lock_commands:  bool,
	delayed_paste:  editing.Delayed_Paste,
	delayed_cut:    editing.Delayed_Cut,
}

// filepath_boundary returns the end of the leftmost token of a generated tag
// prefix (the first space, or the whole string when there is no space).
filepath_boundary :: proc(generated: string) -> int {
	for index in 0 ..< len(generated) {
		if generated[index] == ' ' {
			return index
		}
	}
	return len(generated)
}

init :: proc(state: ^State, generated: string, allocator := context.allocator) -> errs.Error {
	if len(generated) == 0 || len(generated) > MAX_GENERATED_BYTES {
		return errs.newf(.Invalid_Input, "tag: generated prefix must contain 1..%d bytes", MAX_GENERATED_BYTES, allocator = allocator)
	}
	state^ = {}
	if err := txn.doc_init_from_bytes(&state.doc, transmute([]byte)generated, {}, allocator); !errs.ok(err) {
		return err
	}
	state.generated_end = len(generated)
	state.filepath_end = filepath_boundary(generated)
	state.lock_commands = true
	return {}
}

destroy :: proc(state: ^State) {
	txn.doc_destroy(&state.doc)
	state^ = {}
}

refresh_generated :: proc(state: ^State, generated: string, allocator := context.allocator) -> errs.Error {
	if len(generated) == 0 || len(generated) > MAX_GENERATED_BYTES {
		return errs.newf(.Invalid_Input, "tag: generated prefix must contain 1..%d bytes", MAX_GENERATED_BYTES, allocator = allocator)
	}
	read_length := min(rope.tree_byte_count(&state.doc.tree), MAX_GENERATED_BYTES)
	current, err := rope.tree_read_all(&state.doc.tree, {0, read_length}, allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(current, allocator)
	prefix_end := 0
	if len(current) >= 3 {
		for index in 0 ..= len(current) - 3 {
			if current[index] == ' ' && current[index + 1] == '|' && current[index + 2] == ' ' {
				prefix_end = index + 3
				break
			}
		}
	}
	if string(current[:prefix_end]) == generated {
		state.generated_end = prefix_end
		state.filepath_end = filepath_boundary(generated)
		return {}
	}

	operation := txn.Replace {
		range = {0, prefix_end},
		data = transmute([]byte)generated,
	}
	anchor := txn.Anchor{pos = state.selection.anchor, affinity = state.selection.affinity}
	active := txn.Anchor{pos = state.selection.active, affinity = state.selection.affinity}
	txn.anchor_apply_op(&anchor, operation)
	txn.anchor_apply_op(&active, operation)
	after := txn.Selection {
		anchor = anchor.pos,
		active = active.pos,
		affinity = state.selection.affinity,
	}
	ops := []txn.Operation{operation}
	transaction := txn.Transaction {
		source = .Edit,
		base_revision = txn.doc_revision(&state.doc),
		ops = ops,
		after_selection = after,
	}
	if apply_err := txn.doc_apply(&state.doc, &transaction, allocator); !errs.ok(apply_err) {
		return apply_err
	}
	state.generated_end = len(generated)
	state.filepath_end = filepath_boundary(generated)
	state.selection = after
	return {}
}

// refresh_commands replaces only the generated-commands region (between the
// filepath token and the ` | ` delimiter) with the given command list, leaving
// the user's filepath token and suffix untouched. The caller must have run
// rediscover first so filepath_end/generated_end are current. A selection
// inside the filepath (at or before filepath_end) is preserved in place; a
// selection at or past the commands region is anchored through the replace.
refresh_commands :: proc(state: ^State, commands: string, allocator := context.allocator) -> errs.Error {
	if state.generated_end == 0 {
		return {}
	}
	replacement := strings.concatenate({" ", commands, " | "}, allocator)
	defer delete(replacement, allocator)
	current, err := rope.tree_read_all(&state.doc.tree, {state.filepath_end, state.generated_end}, allocator)
	if !errs.ok(err) {
		return err
	}
	same := string(current) == replacement
	delete(current, allocator)
	if same {
		return {}
	}

	selection := state.selection
	in_filepath := selection.anchor <= state.filepath_end && selection.active <= state.filepath_end
	operation := txn.Replace {
		range = {state.filepath_end, state.generated_end},
		data = transmute([]byte)replacement,
	}
	if !in_filepath {
		anchor := txn.Anchor{pos = selection.anchor, affinity = selection.affinity}
		active := txn.Anchor{pos = selection.active, affinity = selection.affinity}
		txn.anchor_apply_op(&anchor, operation)
		txn.anchor_apply_op(&active, operation)
		selection = txn.Selection{anchor = anchor.pos, active = active.pos, affinity = state.selection.affinity}
	}
	ops := []txn.Operation{operation}
	transaction := txn.Transaction {
		source = .Edit,
		base_revision = txn.doc_revision(&state.doc),
		ops = ops,
		after_selection = selection,
	}
	if apply_err := txn.doc_apply(&state.doc, &transaction, allocator); !errs.ok(apply_err) {
		return apply_err
	}
	state.generated_end = state.filepath_end + len(replacement)
	state.selection = selection
	return {}
}

text :: proc(state: ^State, allocator := context.allocator) -> (string, errs.Error) {
	bytes, err := rope.tree_read_all(&state.doc.tree, {0, rope.tree_byte_count(&state.doc.tree)}, allocator)
	if !errs.ok(err) {
		return "", err
	}
	defer delete(bytes, allocator)
	return strings.clone(string(bytes), allocator), {}
}

// edit_allowed reports whether inserting text at byte offset `start` is
// permitted. The generated-commands region after the leftmost filepath token
// (and before the ` | ` delimiter) is immutable against typing; the filepath
// itself — up to and including its separating space — stays editable so a new
// name can be typed. When lock_commands is false the whole tag is editable.
edit_allowed :: proc(state: ^State, start: int) -> bool {
	if !state.lock_commands {
		return true
	}
	return start <= state.filepath_end || start >= state.generated_end
}

// deletion_allowed reports whether deleting at the current selection is
// permitted. The generated-commands region is immutable, so a deletion whose
// caret or selection falls inside it is rejected; movement still navigates
// through it. When lock_commands is false the whole tag is editable.
deletion_allowed :: proc(state: ^State, selection: txn.Selection) -> bool {
	if !state.lock_commands {
		return true
	}
	range := editing.selection_range(selection)
	return range.end <= state.filepath_end || range.start >= state.generated_end
}

// filepath returns the leftmost mutable token (the window filepath/name) of the
// tag. The result is owned by the caller and must be freed.
filepath :: proc(state: ^State, allocator := context.allocator) -> (string, errs.Error) {
	end := min(state.filepath_end, rope.tree_byte_count(&state.doc.tree))
	bytes, err := rope.tree_read_all(&state.doc.tree, {0, end}, allocator)
	if !errs.ok(err) {
		return "", err
	}
	defer delete(bytes, allocator)
	return strings.clone(string(bytes), allocator), {}
}

// rediscover recomputes filepath_end and generated_end from the current tag
// text after a user edit. It finds the ` | ` delimiter separating the generated
// prefix from the user suffix; when the delimiter is absent (the prefix was
// edited away), both boundaries collapse so nothing is treated as immutable.
rediscover :: proc(state: ^State, allocator := context.allocator) -> errs.Error {
	total := rope.tree_byte_count(&state.doc.tree)
	current, err := rope.tree_read_all(&state.doc.tree, {0, total}, allocator)
	if !errs.ok(err) {
		return err
	}
	defer delete(current, allocator)
	generated_end := 0
	if len(current) >= 3 {
		for index in 0 ..= len(current) - 3 {
			if current[index] == ' ' && current[index + 1] == '|' && current[index + 2] == ' ' {
				generated_end = index + 3
				break
			}
		}
	}
	state.generated_end = generated_end
	state.filepath_end = generated_end if generated_end == 0 else filepath_boundary(string(current[:generated_end]))
	return {}
}
