// Branching in-memory undo (M02.07), in package txn.
//
// The M02.05 log is the undo tree (SPECS.md §8.4): every applied
// transaction is a node with parent/child links, transaction metadata,
// a timestamp, before/after roots (retained by the persistent tree),
// and the selection state before and after the edit. The document's
// current position is `doc.current` (a Transaction_ID; 0 is the
// initial state). Undo and redo move that position and reassign the
// tree root pointer — no tree mutation, no allocation.
//
// Branching: undoing and applying a new edit appends a sibling node;
// the abandoned branch is never destroyed (its nodes and roots stay in
// the log). Redo follows the most recently applied child of the
// current state — the deterministic "active branch" rule; arbitrary
// branch jumps are M14's interactive tree.
//
// Grouping (SPECS.md §8.5): consecutive transactions sharing a
// nonzero `grouping_key` (one typing run, one paste, ...) form one
// undo unit. Undo jumps past the whole maximal run; redo restores the
// whole run.
//
// Selection state (SPECS.md §8.3): `Selection` records the anchor end,
// the active end (the direction-preserving pair), the affinity, and
// the preferred visual column. M06 owns real selection behavior; the
// txn layer validates bounds at apply time and records/restores the
// state. `visual_column` is 0 when no column is preferred.
package txn

import errs "../errs"

// Selection is the recorded selection state of an undo node
// (SPECS.md §8.3): byte offsets for the anchor and active ends
// (direction is preserved by which is which), the affinity, and the
// preferred visual column (0 = none; real column policy is M06's).
Selection :: struct {
	anchor:        int,
	active:        int,
	affinity:      Affinity,
	visual_column: f64,
}

// selection_in_bounds reports whether both selection ends lie within
// [0, byte_count].
selection_in_bounds :: proc(sel: Selection, byte_count: int) -> bool {
	return sel.anchor >= 0 && sel.anchor <= byte_count &&
		sel.active >= 0 && sel.active <= byte_count
}

// doc_undoable reports whether undo can move the document (the current
// state is not the initial state). Every node has a parent — the
// initial state itself — so this is exactly `current != 0`.
doc_undoable :: proc(doc: ^Doc) -> bool {
	return doc.current != 0
}

// doc_redoable reports whether redo can move the document (the current
// state has at least one applied child).
doc_redoable :: proc(doc: ^Doc) -> bool {
	return redo_child(doc) != 0
}

// doc_undo moves the document to the state before the current
// grouping run and returns the selection to restore (the undone
// group's `before_selection`). At the initial state it is `.NotFound`.
// The tree root is reassigned to the undone node's `before_root` — a
// retained snapshot; no tree mutation or allocation happens.
doc_undo :: proc(doc: ^Doc, allocator := context.allocator) -> (Selection, errs.Error) {
	if doc.current == 0 {
		return Selection{}, errs.newf(
			.NotFound,
			"txn: nothing to undo (at the initial state)",
			allocator = allocator,
		)
	}
	leader := group_leader(doc, doc.current)
	target := doc.log[leader - 1].parent
	restored := doc.log[leader - 1].before_selection
	doc.current = target
	doc.tree.root = doc.log[leader - 1].before_root
	doc.revision = target == 0 ? 0 : doc.log[target - 1].after
	return restored, {}
}

// doc_redo moves the document to the end of the grouping run starting
// at the most recently applied child of the current state and returns
// the selection to restore (the target's `after_selection`). At a
// state without children it is `.NotFound`. No tree mutation or
// allocation happens.
doc_redo :: proc(doc: ^Doc, allocator := context.allocator) -> (Selection, errs.Error) {
	child := redo_child(doc)
	if child == 0 {
		return Selection{}, errs.newf(
			.NotFound,
			"txn: nothing to redo (the current state has no children)",
			allocator = allocator,
		)
	}
	target := group_leaf(doc, child)
	doc.current = target
	doc.tree.root = doc.log[target - 1].after_root
	doc.revision = doc.log[target - 1].after
	return doc.log[target - 1].after_selection, {}
}

// redo_child returns the most recently applied child of the current
// state (0 when there is none). The initial state has no entry; its
// children are the root children — the entry with parent 0 and the
// highest id.
redo_child :: proc(doc: ^Doc) -> Transaction_ID {
	if doc.current != 0 {
		children := doc.log[doc.current - 1].children
		if len(children) > 0 {
			return children[len(children) - 1]
		}
		return 0
	}
	for i := len(doc.log) - 1; i >= 0; i -= 1 {
		if doc.log[i].parent == 0 {
			return doc.log[i].id
		}
	}
	return 0
}

// group_leader returns the topmost node of the grouping run that
// contains `n`: walk up while the parent shares `n`'s nonzero
// grouping_key. Nodes with key 0 (or whose parent differs) are their
// own group.
group_leader :: proc(doc: ^Doc, n: Transaction_ID) -> Transaction_ID {
	node := n
	for node != 0 {
		entry := &doc.log[node - 1]
		if entry.grouping_key == 0 || entry.parent == 0 {
			break
		}
		if doc.log[entry.parent - 1].grouping_key != entry.grouping_key {
			break
		}
		node = entry.parent
	}
	return node
}

// group_leaf descends from `n` through the most recently applied
// child chain while keys match — the redo target of a group (redo
// restores the whole run, landing at its last node).
group_leaf :: proc(doc: ^Doc, n: Transaction_ID) -> Transaction_ID {
	node := n
	for {
		entry := &doc.log[node - 1]
		if entry.grouping_key == 0 {
			break
		}
		children := entry.children
		if len(children) == 0 {
			break
		}
		child := children[len(children) - 1]
		if doc.log[child - 1].grouping_key != entry.grouping_key {
			break
		}
		node = child
	}
	return node
}
