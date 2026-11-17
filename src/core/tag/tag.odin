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
	delayed_paste:  editing.Delayed_Paste,
	delayed_cut:    editing.Delayed_Cut,
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
	state.selection = after
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
