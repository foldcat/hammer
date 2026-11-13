// Full-stack randomized differential (M02.08): `hammer:core/txn` —
// random multi-op transactions with grouping keys and selections,
// undo/redo with branching, checked against independent reference
// models for the whole rope/txn stack after every transaction:
//
// - content (the reference undo tree's snapshots),
// - the undo-tree structure (ids, revisions, parent/child lists),
// - metrics via an independent counting oracle,
// - coordinate conversions via an independent linear-scan model,
// - document invariants via `doc_check`.
//
// This ties the M02.02–M02.07 differential discipline into one test:
// one seeded xorshift64 stream drives the whole stack, and every
// subsystem is mirrored by a reference implementation written
// differently from the one under test. The reference helpers (the
// undo-tree model and operation ordering) live in undo_test.odin and
// txn_test.odin; this file adds the metric oracle and the coordinate
// model.
package txn_test

import "core:bytes"
import "core:fmt"
import "core:testing"

import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

// stack_oracle_metrics counts content metrics with an implementation
// independent of the rope's decode paths (a different loop shape, the
// counting rules re-derived by hand). Comparing the tree's folded
// metrics against this oracle catches policy bugs shared by
// `metrics_of` and `combine`.
stack_oracle_metrics :: proc(data: []byte) -> rope.Metrics {
	m := rope.Metrics{byte_count = len(data)}
	j := 0
	for j < len(data) {
		b := data[j]
		if b < 0x80 || b > 0xF4 || (b >= 0x80 && b <= 0xBF) || b == 0xC0 || b == 0xC1 {
			m.scalar_count += 1
			j += 1
			continue
		}
		expect := 1
		if b >= 0xE0 && b <= 0xEF {
			expect = 2
		} else if b >= 0xF0 && b <= 0xF4 {
			expect = 3
		}
		n := 0
		for n < expect && j+1+n < len(data) && data[j+1+n] >= 0x80 && data[j+1+n] <= 0xBF {
			n += 1
		}
		m.scalar_count += 1
		j += 1 + n
	}
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			m.lf_count += 1
		} else if data[i] == '\r' && (i+1 == len(data) || data[i+1] != '\n') {
			m.lone_cr_count += 1
		}
	}
	return m
}

// Stack_Coord_Model is the independent per-position coordinate
// mapping, built by linear forward passes (the same policy as the
// M02.04 model, re-declared here because test packages cannot import
// each other).
Stack_Coord_Model :: struct {
	scalar_of_byte: []int, // len n+1
	scalar_start:   []int, // len scalar_count+1
	line_of_byte:   []int, // len n+1
	line_start:     []int, // len line_count
	line_end:       []int, // len line_count
	col_of_byte:    []int, // len n+1
}

stack_model_lead :: proc(b: u8) -> int {
	if b >= 0xC2 && b <= 0xDF {
		return 1
	}
	if b >= 0xE0 && b <= 0xEF {
		return 2
	}
	if b >= 0xF0 && b <= 0xF4 {
		return 3
	}
	return 0
}

stack_build_model :: proc(data: []byte) -> Stack_Coord_Model {
	n := len(data)
	m := Stack_Coord_Model {
		scalar_of_byte = make([]int, n + 1),
		line_of_byte   = make([]int, n + 1),
		col_of_byte    = make([]int, n + 1),
	}

	scalar := 0
	pending := 0
	for i := 0; i < n; i += 1 {
		b := data[i]
		if pending > 0 {
			if b >= 0x80 && b <= 0xBF {
				m.scalar_of_byte[i] = scalar
				pending -= 1
				if pending == 0 {
					scalar += 1
				}
			} else {
				m.scalar_of_byte[i] = scalar + 1
				scalar += 1
				pending = 0
				if l := stack_model_lead(b); l > 0 {
					pending = l
				} else {
					scalar += 1
				}
			}
		} else {
			m.scalar_of_byte[i] = scalar
			if l := stack_model_lead(b); l > 0 {
				pending = l
			} else {
				scalar += 1
			}
		}
	}
	scalar_count := scalar + (1 if pending > 0 else 0)
	m.scalar_of_byte[n] = scalar_count

	m.scalar_start = make([]int, scalar_count + 1)
	for s := 0; s <= scalar_count; s += 1 {
		m.scalar_start[s] = n
	}
	for i := 0; i < n; i += 1 {
		s := m.scalar_of_byte[i]
		if m.scalar_start[s] > i {
			m.scalar_start[s] = i
		}
	}

	line := 0
	prev_cr := false
	for i := 0; i < n; i += 1 {
		b := data[i]
		if prev_cr && b != '\n' {
			line += 1
		}
		m.line_of_byte[i] = line
		prev_cr = false
		if b == '\n' {
			line += 1
		} else if b == '\r' {
			prev_cr = true
		}
	}
	m.line_of_byte[n] = line + (1 if prev_cr else 0)
	line_count := m.line_of_byte[n] + 1

	m.line_start = make([]int, line_count)
	m.line_end = make([]int, line_count)
	for l := 0; l < line_count; l += 1 {
		m.line_start[l] = n
	}
	for i := 0; i < n; i += 1 {
		l := m.line_of_byte[i]
		if m.line_start[l] > i {
			m.line_start[l] = i
		}
	}
	for l := 0; l < line_count - 1; l += 1 {
		m.line_end[l] = m.line_start[l + 1]
	}
	m.line_end[line_count - 1] = n

	for i := 0; i <= n; i += 1 {
		l := m.line_of_byte[i]
		m.col_of_byte[i] = m.scalar_of_byte[i] - m.scalar_of_byte[m.line_start[l]]
	}
	return m
}

stack_model_destroy :: proc(m: ^Stack_Coord_Model) {
	delete(m.scalar_of_byte)
	delete(m.scalar_start)
	delete(m.line_of_byte)
	delete(m.line_start)
	delete(m.line_end)
	delete(m.col_of_byte)
}

// stack_expect_coords compares every sampled conversion of the tree
// against the independent model (sampled to keep the whole-stack test
// bounded; the M02.04 differential already checks every position).
stack_expect_coords :: proc(t: ^testing.T, tree: ^rope.Tree, m: ^Stack_Coord_Model, what: string) {
	n := rope.tree_byte_count(tree)
	testing.expect(t, n == len(m.scalar_of_byte) - 1)
	testing.expect(t, rope.tree_scalar_count(tree) == len(m.scalar_start) - 1)
	testing.expect(t, rope.tree_line_count(tree) == len(m.line_start))

	step := 7
	for b := 0; b <= n; b += step {
		s, serr := rope.tree_byte_to_scalar(tree, b)
		testing.expectf(t, errs.ok(serr) && int(s) == m.scalar_of_byte[b], "%s: byte_to_scalar(%v): got %v want %v", what, b, s, m.scalar_of_byte[b])

		l, lerr := rope.tree_byte_to_line(tree, b)
		testing.expectf(t, errs.ok(lerr) && int(l) == m.line_of_byte[b], "%s: byte_to_line(%v): got %v want %v", what, b, l, m.line_of_byte[b])

		lc, cc, cerr := rope.tree_byte_to_line_col(tree, b)
		testing.expectf(
			t,
			errs.ok(cerr) && int(lc) == m.line_of_byte[b] && int(cc) == m.col_of_byte[b],
			"%s: byte_to_line_col(%v): got %v,%v want %v,%v",
			what,
			b,
			lc,
			cc,
			m.line_of_byte[b],
			m.col_of_byte[b],
		)
	}
	if n % step != 0 {
		b := n
		s, serr := rope.tree_byte_to_scalar(tree, b)
		testing.expectf(t, errs.ok(serr) && int(s) == m.scalar_of_byte[b], "%s: byte_to_scalar(%v)", what, b)
	}
	for s := 0; s < len(m.scalar_start); s += step {
		bp, berr := rope.tree_scalar_to_byte(tree, rope.Scalar_Index(s))
		testing.expectf(t, errs.ok(berr) && bp == m.scalar_start[s], "%s: scalar_to_byte(%v): got %v want %v", what, s, bp, m.scalar_start[s])
	}
	for l := 0; l < len(m.line_start); l += 1 {
		start, serr := rope.tree_line_start(tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(serr) && start == m.line_start[l], "%s: line_start(%v): got %v want %v", what, l, start, m.line_start[l])
		end_pos, eerr := rope.tree_line_end(tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(eerr) && end_pos == m.line_end[l], "%s: line_end(%v): got %v want %v", what, l, end_pos, m.line_end[l])
	}
}

// test_stack_randomized_differential is the M02.08 whole-stack
// property: one seeded stream drives random transactions (with groups
// and selections), undo/redo (with branching), and periodic probes of
// content, metrics, coordinates, and document invariants — each
// against its own independent reference implementation.
@(test)
test_stack_randomized_differential :: proc(t: ^testing.T) {
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
		roll := next(&state) % 100
		if roll < 60 || (!txn.doc_undoable(&doc) && !txn.doc_redoable(&doc)) {
			// Apply a random multi-op transaction against the current
			// content.
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
					op = txn.Operation(txn.Delete{range = rope.Byte_Range{lo, hi}})
				} else {
					lo := int(next(&state) % u64(len(base_content)))
					hi := lo + int(next(&state) % u64(len(base_content) - lo + 1))
					plen := int(next(&state) % 15) + 1
					data := make([]u8, plen, context.allocator)
					for &b in data {
						b = alphabet[int(next(&state) % u64(len(alphabet)))]
					}
					op = txn.Operation(txn.Replace{range = rope.Byte_Range{lo, hi}, data = data})
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
			// Undo, mirroring the reference group walk.
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
			// Redo along the most recently applied child.
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

		// Structural mirrors every step.
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
				"step %v: current node must mirror the reference",
				step,
			)
			ref_kids := make([dynamic]txn.Transaction_ID, context.allocator)
			for j in 0 ..< len(nodes) {
				if nodes[j].parent == ref_current {
					append(&ref_kids, txn.Transaction_ID(j + 1))
				}
			}
			testing.expect(t, len(entry.children) == len(ref_kids), "child count must agree")
			for j in 0 ..< min(len(entry.children), len(ref_kids)) {
				testing.expect(t, entry.children[j] == ref_kids[j], "child lists must agree in apply order")
			}
			delete(ref_kids)
		}

		// Content, invariants, and metrics every 10 steps.
		if step % 10 == 0 {
			want := []u8{}
			if ref_current != 0 {
				want = nodes[ref_current - 1].content
			}
			got := doc_flatten(t, &doc)
			testing.expectf(t, bytes.equal(got, want), "content at step %v", step)
			delete(got)
			expect_doc_ok(t, &doc, fmt.tprintf("step %v", step))

			om := stack_oracle_metrics(want)
			tm := rope.tree_metrics(&doc.tree)
			testing.expectf(
				t,
				tm.byte_count == om.byte_count && tm.scalar_count == om.scalar_count &&
					tm.lf_count == om.lf_count && tm.lone_cr_count == om.lone_cr_count,
				"oracle mismatch at step %v: tree %v vs oracle %v",
				step,
				tm,
				om,
			)
		}

		// Coordinate conversions every 25 steps.
		if step % 25 == 0 {
			want := []u8{}
			if ref_current != 0 {
				want = nodes[ref_current - 1].content
			}
			model := stack_build_model(want)
			stack_expect_coords(t, &doc.tree, &model, fmt.tprintf("step %v", step))
			stack_model_destroy(&model)
		}
	}

	// Final full comparison.
	want := []u8{}
	if ref_current != 0 {
		want = nodes[ref_current - 1].content
	}
	got := doc_flatten(t, &doc)
	defer delete(got)
	testing.expect(t, bytes.equal(got, want), "final content")
	expect_doc_ok(t, &doc, "final")
	om := stack_oracle_metrics(want)
	tm := rope.tree_metrics(&doc.tree)
	testing.expect(
		t,
		tm.byte_count == om.byte_count && tm.scalar_count == om.scalar_count &&
			tm.lf_count == om.lf_count && tm.lone_cr_count == om.lone_cr_count,
		"final metrics vs oracle",
	)
	final_model := stack_build_model(want)
	defer stack_model_destroy(&final_model)
	stack_expect_coords(t, &doc.tree, &final_model, "final")
}
