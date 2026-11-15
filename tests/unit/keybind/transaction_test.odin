package keybind_test

import "core:bytes"
import "core:testing"

import editing "hammer:core/editing"
import errs "hammer:core/errs"
import input "hammer:core/input"
import keybind "hammer:core/keybind"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

@(test)
test_resolved_input_sequence_matches_transaction_model :: proc(t: ^testing.T) {
	doc: txn.Doc
	init_err := txn.doc_init(&doc, {chunk_size = 4})
	testing.expect(t, errs.ok(init_err))
	defer txn.doc_destroy(&doc)
	selection := txn.Selection{}
	copy_count := 0

	events := []input.Event {
		input.Text{text = 'a'},
		input.Key_Down{key = .C, modifiers = {.Ctrl}},
		input.Text{text = 'c', modifiers = {.Ctrl}},
		input.Key_Down{key = .Enter},
		input.Text{text = '中', modifiers = {.Ctrl, .Alt}},
		input.Key_Down{key = .Backspace},
		input.Text{text = '\n'},
		input.Key_Down{key = .Tab},
	}
	for event in events {
		action, ok := keybind.resolve_event(event, selection.anchor != selection.active)
		if !ok {
			continue
		}
		err: errs.Error
		#partial switch a in action {
		case editing.Insert_Text:
			err = editing.perform(&doc, &selection, a)
		case editing.Delete_Backward:
			err = editing.perform(&doc, &selection, a)
		case editing.Delete_Forward:
			err = editing.perform(&doc, &selection, a)
		case keybind.Copy:
			copy_count += 1
		case:
		}
		testing.expectf(t, errs.ok(err), "%v: %v", event, errs.describe(err))
		errs.destroy(&err)
	}

	got, read_err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)})
	defer delete(got)
	testing.expect(t, errs.ok(read_err))
	testing.expectf(t, bytes.equal(got, transmute([]byte)string("a\n\t")), "got %q", string(got))
	testing.expect(t, copy_count == 1)
	testing.expect(t, selection.anchor == 3 && selection.active == 3)
	testing.expect(t, txn.doc_log_len(&doc) == 5)
	check_err := txn.doc_check(&doc)
	defer errs.destroy(&check_err)
	testing.expect(t, errs.ok(check_err))
}
