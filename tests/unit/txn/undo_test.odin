// Tests for branching in-memory undo (M02.07): `hammer:core/txn` —
// linear undo/redo with selection restore, branching (undo + new edit
// keeps the abandoned branch), grouping via `grouping_key`, selection
// recording and validation, timestamps, anchors across branches, and
// a randomized differential against an independent reference tree.
package txn_test

import "core:bytes"
import "core:fmt"
import "core:testing"
import "core:time"

import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

// expect_selection compares two selection states field by field.
expect_selection :: proc(t: ^testing.T, got, want: txn.Selection, what: string) {
	testing.expectf(
		t,
		got.anchor == want.anchor && got.active == want.active &&
			got.affinity == want.affinity && got.visual_column == want.visual_column,
		"%s: got {%v, %v, %v, %v}, want {%v, %v, %v, %v}",
		what,
		got.anchor,
		got.active,
		got.affinity,
		got.visual_column,
		want.anchor,
		want.active,
		want.affinity,
		want.visual_column,
	)
}

// sel builds a Selection state.
sel :: proc(anchor, active: int, affinity: txn.Affinity, column: f64) -> txn.Selection {
	return txn.Selection{anchor = anchor, active = active, affinity = affinity, visual_column = column}
}

// test_undo_redo_linear pins linear undo/redo: content, revisions, and
// selection restore at each step, plus the boundary errors.
@(test)
test_undo_redo_linear :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	// t1: "hello" (rev 1), selection after: 0..5.
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "hello")}, after_selection = sel(0, 5, .Right, 3)}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	// t2: "hello world" (rev 2), selection after: 6..11.
	tr = {source = .Typing, base_revision = 1, ops = {insert_op(5, " world")}, after_selection = sel(6, 11, .Right, 6)}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	// t3: "hi world" (rev 3), selection after: 1..1.
	tr = {source = .Edit, base_revision = 2, ops = {replace_op(0, 5, "hi")}, after_selection = sel(1, 1, .Left, 0)}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

	states := []string{"", "hello", "hello world", "hi world"}
	sels_after := []txn.Selection {
		sel(0, 0, .Left, 0), // initial state
		sel(0, 5, .Right, 3),
		sel(6, 11, .Right, 6),
		sel(1, 1, .Left, 0),
	}

	testing.expect(t, txn.doc_undoable(&doc))
	testing.expect(t, !txn.doc_redoable(&doc))

	for rev := 3; rev >= 0; rev -= 1 {
		got := doc_flatten(t, &doc)
		testing.expectf(t, bytes.equal(got, bytes_of(states[rev])), "content at revision %v", rev)
		delete(got)
		expect_doc_ok(t, &doc, fmt.tprintf("revision %v", rev))

		if rev == 0 {
			break
		}
		restored, uerr := txn.doc_undo(&doc)
		testing.expect(t, errs.ok(uerr), "undo must succeed")
		expect_selection(t, restored, sels_after[rev - 1], fmt.tprintf("undo to revision %v restores selection", rev - 1))
		testing.expect(t, txn.doc_revision(&doc) == u64(rev - 1))
		testing.expect(t, doc.current == txn.Transaction_ID(rev - 1))
	}

	// At the initial state: undo is .NotFound, the doc is untouched.
	testing.expect(t, !txn.doc_undoable(&doc))
	testing.expect(t, txn.doc_redoable(&doc))
	_, uerr := txn.doc_undo(&doc)
	testing.expect(t, uerr.kind == .NotFound)
	errs.destroy(&uerr)
	testing.expect(t, txn.doc_revision(&doc) == 0)

	// Redo back down the same chain.
	for rev := 0; rev < 3; rev += 1 {
		got := doc_flatten(t, &doc)
		testing.expectf(t, bytes.equal(got, bytes_of(states[rev])), "content at revision %v before redo", rev)
		delete(got)
		restored, rerr := txn.doc_redo(&doc)
		testing.expect(t, errs.ok(rerr), "redo must succeed")
		expect_selection(t, restored, sels_after[rev + 1], fmt.tprintf("redo to revision %v restores selection", rev + 1))
		testing.expect(t, txn.doc_revision(&doc) == u64(rev + 1))
	}
	testing.expect(t, !txn.doc_redoable(&doc))
	_, rerr := txn.doc_redo(&doc)
	testing.expect(t, rerr.kind == .NotFound)
	errs.destroy(&rerr)

	got := doc_flatten(t, &doc)
	defer delete(got)
	testing.expect(t, bytes.equal(got, bytes_of(states[3])), "final content after redo chain")
	expect_doc_ok(t, &doc, "after redo chain")
}

// test_undo_branching pins SPECS.md §8.4: undoing and applying a new
// edit creates a sibling — the abandoned branch is retained, and redo
// follows the most recently applied child.
@(test)
test_undo_branching :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	apply_edits(t, &doc, {insert_op(0, "base")}) // t1, rev 1
	apply_edits(t, &doc, {insert_op(0, "A")}) // t2, rev 2: "Abase"
	testing.expect(t, txn.doc_undoable(&doc))
	restored, uerr := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr))
	expect_selection(t, restored, sel(0, 0, .Left, 0), "undo to t1")

	got := doc_flatten(t, &doc)
	testing.expect(t, bytes.equal(got, bytes_of("base")), "content after undo")
	delete(got)

	// New edit on the undone state: a sibling of t2, not a replacement.
	apply_edits(t, &doc, {insert_op(0, "B")}) // t3, rev 4: "Bbase"
	got = doc_flatten(t, &doc)
	testing.expect(t, bytes.equal(got, bytes_of("Bbase")), "content of the new branch")
	delete(got)

	// The abandoned node t2 survives, still a child of t1.
	testing.expect(t, txn.doc_log_len(&doc) == 3)
	testing.expect(t, len(doc.log) == 3 && doc.log[0].id == 1)
	testing.expect(t, len(doc.log[0].children) == 2)
	testing.expect(t, doc.log[0].children[0] == 2 && doc.log[0].children[1] == 3)
	testing.expect(t, doc.log[1].parent == 1 && doc.log[2].parent == 1)
	testing.expect(t, doc.current == 3)
	expect_doc_ok(t, &doc, "after branching apply")

	// t2's snapshot still reads "Abase" (persistent roots).
	old, oerr := rope.tree_read_root_all(&doc.tree, doc.log[1].after_root, rope.Byte_Range{0, 5})
	testing.expect(t, errs.ok(oerr))
	testing.expect(t, bytes.equal(old, bytes_of("Abase")), "abandoned snapshot must be retained")
	delete(old)

	// At the leaf, redo is unavailable; undo then redo returns to t3
	// (the most recent child), not the abandoned t2.
	testing.expect(t, !txn.doc_redoable(&doc))
	restored, uerr = txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr))
	testing.expect(t, doc.current == 1)
	testing.expect(t, txn.doc_redoable(&doc))
	_, rerr := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(rerr))
	testing.expect(t, doc.current == 3, "redo must follow the most recent child")
	got = doc_flatten(t, &doc)
	testing.expect(t, bytes.equal(got, bytes_of("Bbase")), "content after redo to the new branch")
	delete(got)
	expect_doc_ok(t, &doc, "after redo to the new branch")
}

// test_undo_grouping pins SPECS.md §8.5: a run of transactions sharing
// a nonzero grouping_key is one undo unit, in both directions.
@(test)
test_undo_grouping :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	// t1 "abc" (key 0), t2 "d" (key 7), t3 "e" (key 7), t4 "f" (key 0).
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "abc")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	tr = {source = .Typing, base_revision = 1, grouping_key = 7, ops = {insert_op(3, "d")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	tr = {source = .Typing, base_revision = 2, grouping_key = 7, ops = {insert_op(4, "e")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	tr = {source = .Typing, base_revision = 3, ops = {insert_op(5, "f")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

	expect_content :: proc(t: ^testing.T, doc: ^txn.Doc, want: string, what: string) {
		got := doc_flatten(t, doc)
		testing.expectf(t, bytes.equal(got, bytes_of(want)), "%s: got %q want %q", what, got, want)
		delete(got)
	}

	expect_content(t, &doc, "abcdef", "before undo")

	// t4 is its own group: undo one step.
	_, uerr1 := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr1))
	testing.expect(t, doc.current == 3)
	expect_content(t, &doc, "abcde", "after undo of t4")

	// t3 and t2 share key 7: undo both at once, landing at t1.
	restored, uerr2 := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr2))
	testing.expect(t, doc.current == 1, "group undo must skip past the whole run")
	expect_content(t, &doc, "abc", "after group undo")
	expect_selection(t, restored, doc.log[0].after_selection, "group undo restores the pre-group selection")

	// Undo t1 to the initial state.
	_, uerr3 := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr3))
	testing.expect(t, doc.current == 0)
	expect_content(t, &doc, "", "after undo to the initial state")

	// Redo: t1, then the whole group t2+t3, then t4.
	_, rerr1 := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(rerr1))
	testing.expect(t, doc.current == 1)
	expect_content(t, &doc, "abc", "redo to t1")
	_, rerr2 := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(rerr2))
	testing.expect(t, doc.current == 3, "group redo must restore the whole run")
	expect_content(t, &doc, "abcde", "redo to the group")
	_, rerr3 := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(rerr3))
	testing.expect(t, doc.current == 4)
	expect_content(t, &doc, "abcdef", "redo to t4")
	expect_doc_ok(t, &doc, "after group undo/redo cycle")

	// A single-node group (nonzero key, different from the parent's)
	// undoes in one step.
	tr = {source = .Typing, base_revision = 4, grouping_key = 9, ops = {insert_op(6, "!")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	expect_content(t, &doc, "abcdef!", "after single-node group apply")
	_, uerr4 := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr4))
	testing.expect(t, doc.current == 4)
	expect_content(t, &doc, "abcdef", "single-node group undo")
	expect_doc_ok(t, &doc, "after single-node group undo")
}

// test_selection_recording pins the per-node selection state: before/
// after values, invalid after-selections, and restore through undo.
@(test)
test_selection_recording :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "abcdef")}, after_selection = sel(1, 3, .Left, 2.5)}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))

	testing.expect(t, len(doc.log) == 1)
	entry := doc.log[0]
	expect_selection(t, entry.before_selection, sel(0, 0, .Left, 0), "first node's before_selection")
	expect_selection(t, entry.after_selection, sel(1, 3, .Left, 2.5), "first node's after_selection")

	tr = {source = .Edit, base_revision = 1, ops = {replace_op(2, 4, "XY")}, after_selection = sel(6, 6, .Right, 0)}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	expect_selection(t, doc.log[1].before_selection, doc.log[0].after_selection, "second node's before_selection")

	// Undo/redo restore the recorded selections.
	restored, uerr := txn.doc_undo(&doc)
	testing.expect(t, errs.ok(uerr))
	expect_selection(t, restored, sel(1, 3, .Left, 2.5), "undo restores the previous selection")
	redone, rerr := txn.doc_redo(&doc)
	testing.expect(t, errs.ok(rerr))
	expect_selection(t, redone, sel(6, 6, .Right, 0), "redo restores the redone selection")

	// An after_selection outside the post-edit document is
	// .Invalid_Input with no mutation at all.
	before := doc_flatten(t, &doc)
	defer delete(before)
	tr = {source = .Typing, base_revision = 2, ops = {insert_op(0, "Q")}, after_selection = sel(99, 100, .Left, 0)}
	err := txn.doc_apply(&doc, &tr)
	testing.expect(t, err.kind == .Invalid_Input, "out-of-range after_selection must be rejected")
	errs.destroy(&err)
	after := doc_flatten(t, &doc)
	defer delete(after)
	testing.expect(t, bytes.equal(after, before), "rejected selection must not change content")
	testing.expect(t, txn.doc_revision(&doc) == 2)
	testing.expect(t, txn.doc_log_len(&doc) == 2)

	tr = {source = .Typing, base_revision = 2, ops = {insert_op(0, "Q")}, after_selection = sel(-1, 0, .Left, 0)}
	err = txn.doc_apply(&doc, &tr)
	testing.expect(t, err.kind == .Invalid_Input, "negative selection must be rejected")
	errs.destroy(&err)
	expect_doc_ok(t, &doc, "after selection rejections")
}

// test_node_timestamp pins that every node records a wall-clock
// timestamp between the apply's start and end.
@(test)
test_node_timestamp :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 4})))
	defer txn.doc_destroy(&doc)

	before := time.now()
	tr: txn.Transaction
	tr = {source = .Typing, base_revision = 0, ops = {insert_op(0, "x")}}
	testing.expect(t, errs.ok(txn.doc_apply(&doc, &tr)))
	after := time.now()

	ts := doc.log[0].timestamp
	testing.expect(t, time.diff(before, ts) >= 0, "timestamp must not precede the apply")
	testing.expect(t, time.diff(ts, after) >= 0, "timestamp must not follow the apply")
}

// test_anchor_across_branches pins the M02.07 anchor contract: replay
// along the current path; anchors on abandoned branches are .Conflict.
@(test)
test_anchor_across_branches :: proc(t: ^testing.T) {
	doc: txn.Doc
	anchor_doc(t, &doc, "abcdef") // t1, rev 1: "abcdef"
	defer txn.doc_destroy(&doc)

	apply_edits(t, &doc, {insert_op(3, "X")}) // t2, rev 2: "abcXdef"
	apply_edits(t, &doc, {insert_op(0, "Y")}) // t3, rev 3: "YabcXdef"

	// Capture anchors on the t3 state, then undo to t2 and branch.
	ab, aberr := txn.anchor_at(&doc, 0, .Left) // rev 3 (t3)
	testing.expect(t, errs.ok(aberr))
	on_path, operr := txn.anchor_at(&doc, 1, .Left) // rev 3 as well
	testing.expect(t, errs.ok(operr))

	restored, uerr := txn.doc_undo(&doc) // -> t2, rev 2
	testing.expect(t, errs.ok(uerr))
	expect_selection(t, restored, doc.log[1].after_selection, "undo to t2 restores t2's selection")
	path_anchor, perr := txn.anchor_at(&doc, 1, .Left) // rev 2 (t2, on the path)
	testing.expect(t, errs.ok(perr))
	apply_edits(t, &doc, {insert_op(6, "Z")}) // t4, rev 4: "abcXdeZf"

	// The rev-3 anchors belong to the abandoned t3 branch: .Conflict.
	err := txn.anchor_transform(&doc, &ab)
	testing.expect(t, err.kind == .Conflict, "anchor on an abandoned branch must conflict")
	errs.destroy(&err)
	err = txn.anchor_transform(&doc, &on_path)
	testing.expect(t, err.kind == .Conflict, "anchor on an abandoned branch must conflict (2)")
	errs.destroy(&err)

	// A rev-2 anchor is on the current path: replay only t4's ops.
	err = txn.anchor_transform(&doc, &path_anchor)
	testing.expect(t, errs.ok(err) && path_anchor.pos == 1, "path anchor transformed through t4 only")
	testing.expect(t, path_anchor.revision == txn.doc_revision(&doc))

	// At the current revision: no-op.
	cur, cerr := txn.anchor_at(&doc, 0, .Left)
	testing.expect(t, errs.ok(cerr))
	err = txn.anchor_transform(&doc, &cur)
	testing.expect(t, errs.ok(err) && cur.pos == 0, "current-revision anchor is a no-op")

	// Ahead of the document: .Invalid_Input.
	future: txn.Anchor
	future = {pos = 0, affinity = .Left, revision = txn.doc_revision(&doc) + 1}
	err = txn.anchor_transform(&doc, &future)
	testing.expect(t, err.kind == .Invalid_Input)
	errs.destroy(&err)

	// Undo to t1, redo chain: t2 then t4 (most recent child of t2).
	_, uerr2 := txn.doc_undo(&doc) // t4 -> t2
	testing.expect(t, errs.ok(uerr2))
	_, uerr3 := txn.doc_undo(&doc) // t2 -> t1
	testing.expect(t, errs.ok(uerr3))
	testing.expect(t, doc.current == 1)
	_, rerr1 := txn.doc_redo(&doc) // -> t2
	testing.expect(t, errs.ok(rerr1))
	_, rerr2 := txn.doc_redo(&doc) // -> t4, not t3
	testing.expect(t, errs.ok(rerr2))
	testing.expect(t, doc.current == 4, "redo follows the most recent child, not the abandoned t3")

	// The abandoned t3's anchor is still .Conflict at rev 4.
	err = txn.anchor_transform(&doc, &ab)
	testing.expect(t, err.kind == .Conflict, "abandoned-branch anchor conflicts after redo")
	errs.destroy(&err)
	expect_doc_ok(t, &doc, "after branch anchor walk")
}

// Ref_Node mirrors one undo-tree node for the reference model
// (independent of the doc's structures).
Ref_Node :: struct {
	parent:    txn.Transaction_ID,
	key:       u64,
	revision:  u64,
	ops:       []txn.Operation, // applied order, owned
	content:   []u8, // snapshot after the node, owned
	after_sel: txn.Selection,
}

// Undo_Anchor tracks one anchor on both sides (in-place on both).
Undo_Anchor :: struct {
	anchor:   txn.Anchor, // the doc's in-place anchor
	ref_pos:  int, // the reference's in-place position
	ref_rev:  u64, // the reference's in-place stamped revision
	affinity: txn.Affinity,
}

// ref_redo_child finds the most recently applied child of `current`
// by scanning the node array backwards (the reference's own way).
ref_redo_child :: proc(nodes: []Ref_Node, current: txn.Transaction_ID) -> txn.Transaction_ID {
	for i := len(nodes) - 1; i >= 0; i -= 1 {
		if nodes[i].parent == current {
			return txn.Transaction_ID(i + 1)
		}
	}
	return 0
}

// ref_group_leader walks up from `n` while the parent shares `n`'s
// nonzero grouping key.
ref_group_leader :: proc(nodes: []Ref_Node, n: txn.Transaction_ID) -> txn.Transaction_ID {
	node := n
	for node != 0 {
		parent := nodes[node - 1].parent
		if nodes[node - 1].key == 0 || parent == 0 {
			break
		}
		if nodes[parent - 1].key != nodes[node - 1].key {
			break
		}
		node = parent
	}
	return node
}

// ref_group_leaf descends from `n` through the most recent child chain
// while keys match.
ref_group_leaf :: proc(nodes: []Ref_Node, n: txn.Transaction_ID) -> txn.Transaction_ID {
	node := n
	for nodes[node - 1].key != 0 {
		child := ref_redo_child(nodes, node)
		if child == 0 {
			break
		}
		if nodes[child - 1].key != nodes[node - 1].key {
			break
		}
		node = child
	}
	return node
}

// ref_anchor_step transforms the reference anchor in place and returns
// the expected error kind (the policy, independently implemented).
ref_anchor_step :: proc(
	nodes: []Ref_Node,
	current: txn.Transaction_ID,
	pos: ^int,
	rev: ^u64,
	affinity: txn.Affinity,
) -> errs.Kind {
	cur_rev := u64(0)
	if current != 0 {
		cur_rev = nodes[current - 1].revision
	}
	if rev^ > cur_rev {
		return .Invalid_Input
	}
	if rev^ == cur_rev {
		return .None
	}
	// Walk up looking for the anchor's node on the current path.
	ancestor := current
	for ancestor != 0 && nodes[ancestor - 1].revision != rev^ {
		ancestor = nodes[ancestor - 1].parent
	}
	if ancestor == 0 && rev^ != 0 {
		return .Conflict
	}
	// Replay the nodes below the anchor's node, in apply order.
	order := make([dynamic]txn.Transaction_ID, context.allocator)
	defer delete(order)
	for n := current; n != 0 && nodes[n - 1].revision > rev^; {
		append(&order, n)
		n = nodes[n - 1].parent
	}
	for i := len(order) - 1; i >= 0; i -= 1 {
		for op in nodes[order[i] - 1].ops {
			ref_anchor_apply(pos, affinity, op)
		}
	}
	rev^ = cur_rev
	return .None
}

// test_undo_randomized_differential drives random apply/undo/redo
// operations with random grouping keys and a pool of anchors, checking
// content, node structure, restored selections, and anchor transforms
// against the independent reference tree after every step.
@(test)
test_undo_randomized_differential :: proc(t: ^testing.T) {
	doc: txn.Doc
	testing.expect(t, errs.ok(txn.doc_init(&doc, {chunk_size = 5, target_leaf_bytes = 24})))
	defer txn.doc_destroy(&doc)

	alphabet := bytes_of("ab\r\né€😀z中✓")
	nodes := make([dynamic]Ref_Node, context.allocator)
	defer {
		for &n in nodes {
			txn.ops_destroy(n.ops)
			delete(n.content, context.allocator)
		}
		delete(nodes)
	}
	ref_current: txn.Transaction_ID = 0
	ref_next_rev: u64 = 1
	ref_next_id: u64 = 1
	last_key: u64 = 0
	tracked := make([dynamic]Undo_Anchor, context.allocator)
	defer delete(tracked)

	state: u64 = 0x9e37_79b9_7f4a_7c15
	next := proc(x: ^u64) -> u64 {
		v := x^
		v ~= v << 13
		v ~= v >> 7
		v ~= v << 17
		x^ = v
		return v
	}

	ref_revision :: proc(nodes: []Ref_Node, current: txn.Transaction_ID) -> u64 {
		if current == 0 {
			return 0
		}
		return nodes[current - 1].revision
	}

	for step in 0 ..< 600 {
		// Capture an anchor on the current state every 3rd step.
		if step % 3 == 0 {
			cur_rev := ref_revision(nodes[:], ref_current)
			content_len := 0
			if ref_current != 0 {
				content_len = len(nodes[ref_current - 1].content)
			}
			pos := 0
			if content_len > 0 {
				pos = int(next(&state) % u64(content_len + 1))
			}
			affinity := txn.Affinity(next(&state) % 2)
			a, aerr := txn.anchor_at(&doc, pos, affinity)
			testing.expect(t, errs.ok(aerr))
			append(&tracked, Undo_Anchor{anchor = a, ref_pos = pos, ref_rev = cur_rev, affinity = affinity})
		}

		roll := next(&state) % 100
		if roll < 55 || (!txn.doc_undoable(&doc) && !txn.doc_redoable(&doc)) {
			// Apply: random ops computed against the current content.
			base_content: [dynamic]u8
			if ref_current != 0 {
				base_content = make([dynamic]u8, 0, len(nodes[ref_current - 1].content), context.allocator)
				append(&base_content, ..nodes[ref_current - 1].content)
			} else {
				base_content = make([dynamic]u8, context.allocator)
			}
			defer delete(base_content)

			ops := make([dynamic]txn.Operation, context.allocator)
			n_ops := int(next(&state) % 3) + 1
			attempts := 0
			for len(ops) < n_ops && attempts < 12 {
				attempts += 1
				kind := next(&state) % 3
				op: txn.Operation
				if kind == 0 || len(base_content) == 0 {
					pos := int(next(&state) % u64(len(base_content) + 1))
					plen := int(next(&state) % 24) + 1
					data := make([]u8, plen, context.allocator)
					for &b in data {
						b = alphabet[int(next(&state) % u64(len(alphabet)))]
					}
					op = txn.Operation(txn.Insert{pos = pos, data = data})
				} else if kind == 1 {
					lo := int(next(&state) % u64(len(base_content)))
					hi := lo + int(next(&state) % u64(len(base_content) - lo + 1))
					op = txn.Operation(txn.Delete{range = {lo, hi}})
				} else {
					lo := int(next(&state) % u64(len(base_content)))
					hi := lo + int(next(&state) % u64(len(base_content) - lo + 1))
					plen := int(next(&state) % 15) + 1
					data := make([]u8, plen, context.allocator)
					for &b in data {
						b = alphabet[int(next(&state) % u64(len(alphabet)))]
					}
					op = txn.Operation(txn.Replace{range = {lo, hi}, data = data})
				}
				if !ref_overlaps(op, ops[:]) {
					append(&ops, op)
				} else {
					switch o in op {
					case txn.Insert:
						delete(o.data, context.allocator)
					case txn.Replace:
						delete(o.data, context.allocator)
					case txn.Delete:
					}
				}
			}

			// An empty op list is a doc no-op (no node, no counters):
			// mirror it exactly instead of committing a reference node.
			if len(ops) == 0 {
				delete(ops)
				continue
			}

			// Reference first: apply to a copy to learn the new length,
			// then pick a valid selection.
			ref_apply(&base_content, ops[:])
			after_len := len(base_content)
			after_sel := sel(0, 0, .Left, 0)
			if after_len > 0 {
				after_sel = sel(
					int(next(&state) % u64(after_len + 1)),
					int(next(&state) % u64(after_len + 1)),
					txn.Affinity(next(&state) % 2),
					f64(next(&state) % 5),
				)
			}
			// Grouping key: reuse the last one with some probability.
			if last_key != 0 && next(&state) % 10 < 4 {
				// reuse
			} else {
				last_key = u64(next(&state) % 4)
			}
			key := last_key

			tr: txn.Transaction
			tr = {
				source = .Edit,
				base_revision = txn.doc_revision(&doc),
				grouping_key = key,
				ops = ops[:],
				after_selection = after_sel,
			}
			aerr := txn.doc_apply(&doc, &tr)
			if !errs.ok(aerr) {
				adesc := errs.describe(aerr, context.allocator)
				defer delete(adesc, context.allocator)
				testing.expectf(t, false, "apply must not fail: %s", adesc)
				errs.destroy(&aerr)
			}

			// Commit the reference node (mirroring the applied order).
			sorted, serr := txn.ops_copy(ops[:])
			testing.expect(t, errs.ok(serr))
			ref_sort(sorted)
			append(&nodes, Ref_Node {
				parent = ref_current,
				key = key,
				revision = ref_next_rev,
				ops = sorted,
				content = bytes.clone(base_content[:], context.allocator),
				after_sel = after_sel,
			})
			ref_current = txn.Transaction_ID(ref_next_id)
			ref_next_rev += 1
			ref_next_id += 1

			for op in ops {
				switch o in op {
				case txn.Insert:
					delete(o.data, context.allocator)
				case txn.Replace:
					delete(o.data, context.allocator)
				case txn.Delete:
				}
			}
			delete(ops)
		} else if roll < 80 {
			// Undo (only when the doc can; the reference agrees).
			testing.expect(t, txn.doc_undoable(&doc) == (ref_current != 0))
			if !txn.doc_undoable(&doc) {
				_, uerr := txn.doc_undo(&doc)
				testing.expect(t, uerr.kind == .NotFound)
				errs.destroy(&uerr)
			} else {
				leader := ref_group_leader(nodes[:], ref_current)
				target := nodes[leader - 1].parent
				want := txn.Selection{}
				if target != 0 {
					want = nodes[target - 1].after_sel
				}
				restored, uerr := txn.doc_undo(&doc)
				testing.expect(t, errs.ok(uerr), "undo must succeed")
				expect_selection(t, restored, want, fmt.tprintf("step %v undo selection", step))
				ref_current = target
				testing.expect(t, doc.current == ref_current, "current must mirror the reference")
			}
		} else {
			// Redo (only when the doc can; the reference agrees).
			ref_child := ref_redo_child(nodes[:], ref_current)
			testing.expect(t, txn.doc_redoable(&doc) == (ref_child != 0))
			if ref_child == 0 {
				_, rerr := txn.doc_redo(&doc)
				testing.expect(t, rerr.kind == .NotFound)
				errs.destroy(&rerr)
			} else {
				leaf := ref_group_leaf(nodes[:], ref_child)
				restored, rerr := txn.doc_redo(&doc)
				testing.expect(t, errs.ok(rerr), "redo must succeed")
				expect_selection(t, restored, nodes[leaf - 1].after_sel, fmt.tprintf("step %v redo selection", step))
				ref_current = leaf
				testing.expect(t, doc.current == ref_current, "current must mirror the reference")
			}
		}

		// Transform every tracked anchor through both implementations.
		for i in 0 ..< len(tracked) {
			txerr := txn.anchor_transform(&doc, &tracked[i].anchor)
			ref_kind := ref_anchor_step(
				nodes[:],
				ref_current,
				&tracked[i].ref_pos,
				&tracked[i].ref_rev,
				tracked[i].affinity,
			)
			testing.expectf(
				t,
				txerr.kind == ref_kind,
				"anchor %v at step %v: doc kind %v, ref kind %v",
				i,
				step,
				txerr.kind,
				ref_kind,
			)
			errs.destroy(&txerr)
			if ref_kind == .None {
				testing.expectf(
					t,
					tracked[i].anchor.pos == tracked[i].ref_pos,
					"anchor %v at step %v: doc %v, ref %v",
					i,
					step,
					tracked[i].anchor.pos,
					tracked[i].ref_pos,
				)
				testing.expect(t, tracked[i].anchor.revision == ref_revision(nodes[:], ref_current))
			}
		}

		// Mirror the counters, the current node fields, and the child
		// lists every step.
		testing.expect(t, doc.next_id == ref_next_id, "next_id must mirror the reference")
		testing.expect(t, doc.next_revision == ref_next_rev, "next_revision must mirror the reference")
		testing.expect(t, doc.current == ref_current, "current must mirror the reference")
		testing.expect(t, txn.doc_revision(&doc) == ref_revision(nodes[:], ref_current))
		if ref_current != 0 {
			entry := doc.log[ref_current - 1]
			refn := nodes[ref_current - 1]
			testing.expectf(
				t,
				entry.parent == refn.parent && entry.grouping_key == refn.key && entry.after == refn.revision &&
					entry.after_selection == refn.after_sel,
				"step %v: current node %v must mirror the reference",
				step,
				ref_current,
			)
			// Children: the doc's child list vs the reference's scan.
			ref_kids := make([dynamic]txn.Transaction_ID, context.allocator)
			for j in 0 ..< len(nodes) {
				if nodes[j].parent == ref_current {
					append(&ref_kids, txn.Transaction_ID(j + 1))
				}
			}
			testing.expectf(
				t,
				len(entry.children) == len(ref_kids),
				"step %v: node %v child count %v vs %v",
				step,
				ref_current,
				len(entry.children),
				len(ref_kids),
			)
			for j in 0 ..< min(len(entry.children), len(ref_kids)) {
				testing.expect(t, entry.children[j] == ref_kids[j], "child lists must agree in apply order")
			}
			delete(ref_kids)
		}

		if step % 10 == 0 {
			want := []u8{}
			if ref_current != 0 {
				want = nodes[ref_current - 1].content
			}
			got := doc_flatten(t, &doc)
			testing.expectf(t, bytes.equal(got, want), "content at step %v", step)
			delete(got)
			expect_doc_ok(t, &doc, fmt.tprintf("step %v", step))
		}
	}

	got := doc_flatten(t, &doc)
	defer delete(got)
	want := []u8{}
	if ref_current != 0 {
		want = nodes[ref_current - 1].content
	}
	testing.expect(t, bytes.equal(got, want), "final content")
	expect_doc_ok(t, &doc, "final")
}
