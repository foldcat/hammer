// Package txn: transactions, revision tracking, anchors, and the
// branching in-memory undo tree (M02.05–M02.07).
//
// The transaction layer over the persistent rope (SPECS.md §8.1):
// every edit to a document goes through a transaction — typing, paste,
// cut, indentation, Edit commands, IPC writes, command-output
// replacement, save-time formatting, recovery restoration. The `Doc`
// is the single owner of the chunk store, the tree, and the
// transaction-level revision; subsystems read directly but never
// mutate the tree (AGENTS.md §14.1 — enforced by convention: the tree
// is public for reads, `doc_apply` is the only mutation path).
//
// Contracts:
//
// - **Revisions.** `doc.revision` (u64, starts at 0 for the empty
//   initial state) identifies the current history state. It is the
//   buffer revision for stale-rejection and background-result
//   validation (SPECS.md §4.3). Applied transactions draw their
//   `after` revision from a global counter (`doc.next_revision`), so
//   revision values are unique across the whole history tree even
//   though they are not dense: undo back to a state and applying a
//   new edit produces `base = <old revision>, after = <next global
//   revision>`, skipping the abandoned branch's values. The tree's
//   own `revision` field counts internal mutations and is not the
//   buffer revision.
// - **Stale rejection.** A transaction whose `base_revision` does not
//   match the current revision is rejected with `.Conflict` and
//   changes nothing — the revisioned-result contract (SPECS.md §4.3):
//   never apply stale operations silently.
// - **Original-snapshot coordinates** (SPECS.md §8.2). Operations are
//   expressed against the document state at `base_revision`.
//   `doc_apply` validates them (bounds, no overlapping ranges, no
//   duplicate insert positions) and applies them in a deterministic
//   order — descending start position, delete/replace before an
//   insert at the same position — so each operation's original offset
//   stays valid while applying. The log stores the operations in this
//   applied order.
// - **Atomicity.** Validation failures reject the whole transaction
//   before any mutation. If a step fails mid-apply (allocation
//   failure), the root is restored to its pre-transaction value and no
//   counter, log entry, or child link changes — the persistent tree
//   makes rollback a pointer reset; the orphaned nodes and any
//   interned chunks are retained (content-addressed, safe).
// - **The log is the undo tree** (SPECS.md §8.4). Every applied
//   transaction is recorded as a node: parent/child ids, transaction
//   metadata, timestamp, before/after roots, before/after selection
//   state, and an owned deep copy of the operations, in apply order
//   (`doc.log[i].id == i + 1`). Roots stay valid forever (M02.03
//   persistence), so `undo`/`redo` (see undo.odin) jump between
//   states by reassigning the root pointer, and anchor transformation
//   replays the current path. Undo followed by a new edit appends a
//   *sibling* node instead of destroying the abandoned branch. The log
//   is never pruned in M02 (retention/pruning is M04/M14's concern).
// - **Ownership.** The log (with its operation copies and child-id
//   arrays) and error messages use the caller-provided allocators;
//   `doc_destroy` releases them, then the tree and the chunk store.
//
// Backend-free: imports only `core:` packages plus `core/chunk`,
// `core/rope`, and `core/errs` — no Sokol collection (SPECS.md
// §4.2), builds under `-no-crt`.
package txn

import "core:mem"
import "core:time"

import chunk "../chunk"
import errs "../errs"
import rope "../rope"

// Transaction_ID identifies one applied transaction (1-based).
Transaction_ID :: distinct u64

// Source classifies where a transaction came from (SPECS.md §8.1).
Source :: enum u8 {
	None,
	Typing,
	Paste,
	Cut,
	Indent,
	Edit,
	IPC,
	Command_Output,
	Format,
	Recovery,
}

// Insert adds `data` at byte offset `pos` of the base snapshot
// (pos may equal the byte count: append).
Insert :: struct {
	pos:  int,
	data: []byte,
}

// Delete removes the byte range `range` of the base snapshot.
Delete :: struct {
	range: rope.Byte_Range,
}

// Replace removes `range` of the base snapshot and puts `data` in its
// place.
Replace :: struct {
	range: rope.Byte_Range,
	data:  []byte,
}

// Operation is one edit of a transaction, in base-snapshot
// coordinates.
Operation :: union {
	Insert,
	Delete,
	Replace,
}

// Transaction is a batch of non-overlapping edits computed against the
// document state at `base_revision`. `ops` is borrowed for the apply
// call (the log stores its own copy); `id` is assigned by `doc_apply`
// (0 before). `after_selection` is the selection state the edit leaves
// (recorded on the undo node; M06 owns selection semantics — the txn
// layer only validates bounds and records it).
Transaction :: struct {
	id:              Transaction_ID,
	source:          Source,
	base_revision:   u64,
	grouping_key:    u64,
	ops:             []Operation,
	after_selection: Selection,
}

// Log_Entry is one recorded transaction and one node of the undo tree
// (SPECS.md §8.4): the applied (sorted) operations, the before/after
// roots for undo and snapshot reads, the parent/child links, the
// timestamp, and the selection state before and after the edit.
// Entries live in apply order (`doc.log[i].id == i + 1`); `parent`
// and the `children` ids are Transaction_IDs, 0 meaning the initial
// state (which has no entry).
Log_Entry :: struct {
	id:               Transaction_ID,
	source:           Source,
	base:             u64,
	after:            u64,
	grouping_key:     u64,
	parent:           Transaction_ID,
	children:         [dynamic]Transaction_ID, // apply order; last = most recent
	timestamp:        time.Time,
	before_root:      ^rope.Node,
	after_root:       ^rope.Node,
	before_selection: Selection,
	after_selection:  Selection,
	ops:              []Operation, // owned deep copy, applied order
}

// Options configures a Doc at init.
Options :: struct {
	// chunk_size is the chunk store's target chunk size (0 selects
	// the default).
	chunk_size: int,
	// target_leaf_bytes is the rope's leaf size bound (0 selects the
	// default).
	target_leaf_bytes: int,
}

// Doc is a document: text (chunk store + persistent tree), the current
// undo-tree position, a transaction-level revision, and the applied
// log (the undo tree's node array). Treat it as a fixed-location value
// — pass by pointer, never copy it (duplicating the dynamic-array
// headers and the tree pool corrupts state).
Doc :: struct {
	store:        chunk.Store,
	tree:         rope.Tree,
	revision:     u64, // the current node's `after` (0 = initial state)
	current:      Transaction_ID, // current undo-tree node; 0 = initial state
	next_id:      u64, // next Transaction_ID to assign
	next_revision: u64, // global revision counter (see the package doc)
	log:          [dynamic]Log_Entry, // every applied transaction, apply order
}

// doc_init prepares an empty document. The allocator backs the log and
// its operation copies (the tree pool and the chunk store manage their
// own storage). A Doc must be destroyed before it is initialized
// again.
doc_init :: proc(
	doc: ^Doc,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	chunk_size := options.chunk_size
	if chunk_size == 0 {
		chunk_size = chunk.DEFAULT_CHUNK_SIZE
	}
	assert(chunk_size > 0, "txn: options.chunk_size must not be negative")
	chunk.init(&doc.store, {chunk_size = chunk_size})

	tree_options := rope.Options{target_leaf_bytes = options.target_leaf_bytes}
	if ierr := rope.tree_init(&doc.tree, &doc.store, tree_options, allocator); !errs.ok(ierr) {
		chunk.destroy(&doc.store)
		return ierr
	}
	doc.revision = 0
	doc.current = 0
	doc.next_id = 1
	doc.next_revision = 1
	doc.log = make([dynamic]Log_Entry, allocator)
	return {}
}

// doc_destroy releases the document: the log (with its operation
// copies and child-id arrays), the tree, and the chunk store.
doc_destroy :: proc(doc: ^Doc) {
	for &entry in doc.log {
		ops_destroy(entry.ops)
		delete(entry.children)
	}
	delete(doc.log)
	rope.tree_destroy(&doc.tree)
	chunk.destroy(&doc.store)
	doc^ = Doc{}
}

// doc_revision returns the transaction-level revision.
doc_revision :: proc(doc: ^Doc) -> u64 {
	return doc.revision
}

// doc_log_len returns the number of applied transactions.
doc_log_len :: proc(doc: ^Doc) -> int {
	return len(doc.log)
}

// doc_apply validates `txn` against the current revision and applies
// its operations, appending one undo-tree node to the log.
//
// - `txn.base_revision` must equal the current revision, or the
//   transaction is rejected with `.Conflict` and nothing changes.
// - Operations are validated against the base snapshot (bounds, no
//   overlapping ranges, no duplicate insert positions; `.Invalid_Input`
//   violations reject the whole transaction) and applied in
//   deterministic descending order.
// - `txn.after_selection` must lie within [0, byte_count] of the
//   post-edit document (`.Invalid_Input` otherwise).
// - A transaction with no operations (or only empty inserts) is a
//   no-op: no revision bump, no log entry.
// - On success `txn.id` is assigned, the new node's `after` revision
//   comes from the global counter, the node is linked under the
//   current node (or the initial state), and the current state moves
//   to the new node. Applying after an undo creates a sibling node;
//   the abandoned branch is retained (SPECS.md §8.4).
// - On a mid-apply failure (allocation or selection validation) the
//   pre-transaction root is restored and no counter, log entry, or
//   child link changes (`.Resource_Limit` / `.Invalid_Input`).
doc_apply :: proc(
	doc: ^Doc,
	txn: ^Transaction,
	allocator := context.allocator,
) -> errs.Error {
	if txn.base_revision != doc.revision {
		return errs.newf(
			.Conflict,
			"txn: base revision %v does not match the current revision %v",
			txn.base_revision,
			doc.revision,
			allocator = allocator,
		)
	}
	if len(txn.ops) == 0 {
		return {}
	}

	// Validate against the base snapshot.
	if verr := validate_ops(doc, txn.ops, allocator); !errs.ok(verr) {
		return verr
	}

	// Copy and sort into the deterministic application order.
	sorted := make([dynamic]Operation, allocator)
	defer delete(sorted)
	if aerr := reserve(&sorted, len(txn.ops)); aerr != .None {
		return errs.newf(
			.Resource_Limit,
			"txn: reserving the %v-operation list failed: %v",
			len(txn.ops),
			aerr,
			allocator = allocator,
		)
	}
	append(&sorted, ..txn.ops)
	ops_sort(sorted[:])

	// Filter out empty inserts (no-ops).
	effective := false
	for op in sorted {
		switch o in op {
		case Insert:
			if len(o.data) > 0 {
				effective = true
			}
		case Delete, Replace:
			effective = true
		}
	}
	if !effective {
		return {}
	}

	parent := doc.current
	before_root := doc.tree.root
	before_selection := Selection{}
	if parent != 0 {
		before_selection = doc.log[parent - 1].after_selection
	}

	// Apply in order; restore the root on any failure.
	for op in sorted {
		switch o in op {
		case Insert:
			if len(o.data) == 0 {
				continue
			}
			if ierr := rope.tree_insert(&doc.tree, o.pos, o.data, allocator); !errs.ok(ierr) {
				doc.tree.root = before_root
				return ierr
			}
		case Delete:
			if o.range.start == o.range.end {
				continue
			}
			if derr := rope.tree_delete(&doc.tree, o.range, allocator); !errs.ok(derr) {
				doc.tree.root = before_root
				return derr
			}
		case Replace:
			if o.range.start < o.range.end {
				if derr := rope.tree_delete(&doc.tree, o.range, allocator); !errs.ok(derr) {
					doc.tree.root = before_root
					return derr
				}
			}
			if len(o.data) > 0 {
				if ierr := rope.tree_insert(&doc.tree, o.range.start, o.data, allocator); !errs.ok(ierr) {
					doc.tree.root = before_root
					return ierr
				}
			}
		}
	}

	// The selection must describe the post-edit document.
	total := rope.tree_byte_count(&doc.tree)
	if !selection_in_bounds(txn.after_selection, total) {
		doc.tree.root = before_root
		return errs.newf(
			.Invalid_Input,
			"txn: after_selection [%v, %v] outside [0, %v]",
			txn.after_selection.anchor,
			txn.after_selection.active,
			total,
			allocator = allocator,
		)
	}

	// Peek the id and revision; the counters bump only on full success.
	after := doc.next_revision
	txn.id = Transaction_ID(doc.next_id)

	copied, cerr := ops_copy(sorted[:], allocator)
	if !errs.ok(cerr) {
		// The edit is applied but the log copy failed: roll the
		// document back so the apply stays all-or-nothing.
		doc.tree.root = before_root
		txn.id = 0
		return cerr
	}
	if aerr := reserve(&doc.log, len(doc.log) + 1); aerr != .None {
		ops_destroy(copied)
		doc.tree.root = before_root
		txn.id = 0
		return errs.newf(
			.Resource_Limit,
			"txn: growing the log failed: %v",
			aerr,
			allocator = allocator,
		)
	}
	if parent != 0 {
		if aerr := reserve(&doc.log[parent - 1].children, len(doc.log[parent - 1].children) + 1); aerr != .None {
			ops_destroy(copied)
			doc.tree.root = before_root
			txn.id = 0
			return errs.newf(
				.Resource_Limit,
				"txn: growing the child list of node %v failed: %v",
				parent,
				aerr,
				allocator = allocator,
			)
		}
	}

	append(&doc.log, Log_Entry {
		id = txn.id,
		source = txn.source,
		base = txn.base_revision,
		after = after,
		grouping_key = txn.grouping_key,
		parent = parent,
		timestamp = time.now(),
		before_root = before_root,
		after_root = doc.tree.root,
		before_selection = before_selection,
		after_selection = txn.after_selection,
		ops = copied,
	})
	if parent != 0 {
		append(&doc.log[parent - 1].children, txn.id)
	}
	doc.current = txn.id
	doc.revision = after
	doc.next_id += 1
	doc.next_revision += 1
	return {}
}

// doc_check validates the document: tree invariants plus the undo-tree
// structure (dense ids in apply order, strictly increasing global
// revisions, parent/child symmetry, base revisions and before-roots
// matching the parent, the current state matching the tree root).
doc_check :: proc(doc: ^Doc, allocator := context.allocator) -> errs.Error {
	if cerr := rope.tree_check(&doc.tree, allocator); !errs.ok(cerr) {
		return cerr
	}
	for entry, i in doc.log {
		if entry.id != Transaction_ID(i + 1) {
			return errs.newf(
				.Internal,
				"txn: log entry %v has id %v",
				i,
				entry.id,
				allocator = allocator,
			)
		}
		if entry.after <= entry.base {
			return errs.newf(
				.Internal,
				"txn: log entry %v does not advance %v -> %v",
				i,
				entry.base,
				entry.after,
				allocator = allocator,
			)
		}
		if i > 0 && entry.after <= doc.log[i - 1].after {
			return errs.newf(
				.Internal,
				"txn: log entry %v revision %v is not strictly increasing",
				i,
				entry.after,
				allocator = allocator,
			)
		}
		if entry.parent == 0 {
			if entry.base != 0 {
				return errs.newf(
					.Internal,
					"txn: root child %v has base %v, expected 0",
					entry.id,
					entry.base,
					allocator = allocator,
				)
			}
		} else {
			if entry.parent >= entry.id {
				return errs.newf(
					.Internal,
					"txn: log entry %v has parent %v, which does not precede it",
					entry.id,
					entry.parent,
					allocator = allocator,
				)
			}
			p := doc.log[entry.parent - 1]
			if entry.base != p.after {
				return errs.newf(
					.Internal,
					"txn: log entry %v has base %v, expected the parent's revision %v",
					entry.id,
					entry.base,
					p.after,
					allocator = allocator,
				)
			}
			if entry.before_root != p.after_root {
				return errs.newf(
					.Internal,
					"txn: log entry %v before_root does not match parent %v's after_root",
					entry.id,
					entry.parent,
					allocator = allocator,
				)
			}
			if entry.before_selection != p.after_selection {
				return errs.newf(
					.Internal,
					"txn: log entry %v before_selection does not match parent %v's after_selection",
					entry.id,
					entry.parent,
					allocator = allocator,
				)
			}
			if !children_contains(doc, entry.parent, entry.id) {
				return errs.newf(
					.Internal,
					"txn: parent %v's child list does not contain %v",
					entry.parent,
					entry.id,
					allocator = allocator,
				)
			}
		}
		// Nil roots are legitimate: the document may be empty before
		// the first transaction or after a delete-everything one (the
		// snapshot-roots test verifies root contents separately).
		for child, j in entry.children {
			if child <= entry.id || child > Transaction_ID(len(doc.log)) {
				return errs.newf(
					.Internal,
					"txn: node %v child list entry %v has invalid id %v",
					entry.id,
					j,
					child,
					allocator = allocator,
				)
			}
			if j > 0 && entry.children[j - 1] >= child {
				return errs.newf(
					.Internal,
					"txn: node %v child list is not strictly increasing",
					entry.id,
					allocator = allocator,
				)
			}
			if doc.log[child - 1].parent != entry.id {
				return errs.newf(
					.Internal,
					"txn: node %v lists child %v, which points at parent %v",
					entry.id,
					child,
					doc.log[child - 1].parent,
					allocator = allocator,
				)
			}
		}
	}

	// The current state: the doc revision and tree root must match the
	// current node (the initial state is the empty document).
	if doc.current == 0 {
		if doc.revision != 0 {
			return errs.newf(
				.Internal,
				"txn: at the initial state but the revision is %v",
				doc.revision,
				allocator = allocator,
			)
		}
		if doc.tree.root != nil {
			return errs.newf(
				.Internal,
				"txn: at the initial state but the tree root is not nil",
				allocator = allocator,
			)
		}
	} else {
		if doc.current > Transaction_ID(len(doc.log)) {
			return errs.newf(
				.Internal,
				"txn: current node %v does not exist",
				doc.current,
				allocator = allocator,
			)
		}
		cur := doc.log[doc.current - 1]
		if doc.revision != cur.after {
			return errs.newf(
				.Internal,
				"txn: revision %v does not match current node %v's revision %v",
				doc.revision,
				doc.current,
				cur.after,
				allocator = allocator,
			)
		}
		if doc.tree.root != cur.after_root {
			return errs.newf(
				.Internal,
				"txn: tree root does not match current node %v's after_root",
				doc.current,
				allocator = allocator,
			)
		}
	}
	last_after := u64(0)
	if len(doc.log) > 0 {
		last_after = doc.log[len(doc.log) - 1].after
	}
	if doc.next_revision != last_after + 1 {
		return errs.newf(
			.Internal,
			"txn: next_revision is %v, expected %v",
			doc.next_revision,
			last_after + 1,
			allocator = allocator,
		)
	}
	if doc.next_id != u64(len(doc.log)) + 1 {
		return errs.newf(
			.Internal,
			"txn: next_id is %v, expected %v",
			doc.next_id,
			u64(len(doc.log)) + 1,
			allocator = allocator,
		)
	}
	return {}
}

// children_contains reports whether `parent`'s child list contains
// `child`.
children_contains :: proc(doc: ^Doc, parent, child: Transaction_ID) -> bool {
	for id in doc.log[parent - 1].children {
		if id == child {
			return true
		}
	}
	return false
}

// validate_ops checks every operation against the base snapshot and
// each other: bounds, non-overlapping ranges, and unique insert
// positions. Inserts may sit exactly at a range's start or end.
validate_ops :: proc(doc: ^Doc, ops: []Operation, allocator := context.allocator) -> errs.Error {
	total := rope.tree_byte_count(&doc.tree)
	for op, i in ops {
		if !op_is_range(op) {
			p := op_start(op)
			if p < 0 || p > total {
				return errs.newf(
					.Invalid_Input,
					"txn: insert position %v outside [0, %v]",
					p,
					total,
					allocator = allocator,
				)
			}
		} else {
			r := op_range(op)
			if r.start < 0 || r.end < r.start || r.end > total {
				return errs.newf(
					.Invalid_Input,
					"txn: range [%v, %v) outside [0, %v]",
					r.start,
					r.end,
					total,
					allocator = allocator,
				)
			}
		}
		for j := i + 1; j < len(ops); j += 1 {
			if verr := validate_pair(ops[i], ops[j], allocator); !errs.ok(verr) {
				return verr
			}
		}
	}
	return {}
}

// validate_pair rejects overlapping operations: overlapping ranges,
// an insert strictly inside a range, or two inserts at the same
// position.
validate_pair :: proc(a, b: Operation, allocator := context.allocator) -> errs.Error {
	a_range := op_is_range(a)
	b_range := op_is_range(b)
	if a_range && b_range {
		ar := op_range(a)
		br := op_range(b)
		if max(ar.start, br.start) < min(ar.end, br.end) {
			return errs.newf(
				.Invalid_Input,
				"txn: overlapping ranges [%v, %v) and [%v, %v)",
				ar.start,
				ar.end,
				br.start,
				br.end,
				allocator = allocator,
			)
		}
	} else if a_range {
		br := op_range(a)
		p := op_start(b)
		if p > br.start && p < br.end {
			return errs.newf(
				.Invalid_Input,
				"txn: insert at %v inside range [%v, %v)",
				p,
				br.start,
				br.end,
				allocator = allocator,
			)
		}
	} else if b_range {
		ar := op_range(b)
		p := op_start(a)
		if p > ar.start && p < ar.end {
			return errs.newf(
				.Invalid_Input,
				"txn: insert at %v inside range [%v, %v)",
				p,
				ar.start,
				ar.end,
				allocator = allocator,
			)
		}
	} else {
		if op_start(a) == op_start(b) {
			return errs.newf(
				.Invalid_Input,
				"txn: two inserts at position %v",
				op_start(a),
				allocator = allocator,
			)
		}
	}
	return {}
}

// op_start returns the base-snapshot start position of an operation.
op_start :: proc(op: Operation) -> int {
	switch o in op {
	case Insert:
		return o.pos
	case Delete:
		return o.range.start
	case Replace:
		return o.range.start
	}
	return 0
}

// op_is_range reports whether the operation removes a range (delete or
// replace).
op_is_range :: proc(op: Operation) -> bool {
	switch o in op {
	case Insert:
		return false
	case Delete, Replace:
		return true
	}
	return false
}

// op_range returns the range of a delete/replace operation.
op_range :: proc(op: Operation) -> rope.Byte_Range {
	switch o in op {
	case Insert:
		return {}
	case Delete:
		return o.range
	case Replace:
		return o.range
	}
	return {}
}

// op_less is the deterministic application order: descending start
// position; a range operation before an insert at the same position
// (the range removes first, then the insert lands where it should).
op_less :: proc(a, b: Operation) -> bool {
	as, bs := op_start(a), op_start(b)
	if as != bs {
		return as > bs
	}
	return op_is_range(a) && !op_is_range(b)
}

// ops_sort orders the operations deterministically (insertion sort —
// transactions hold a handful of operations).
ops_sort :: proc(ops: []Operation) {
	for i := 1; i < len(ops); i += 1 {
		v := ops[i]
		j := i - 1
		for j >= 0 && op_less(v, ops[j]) {
			ops[j + 1] = ops[j]
			j -= 1
		}
		ops[j + 1] = v
	}
}

// ops_copy deep-copies operations (with their data) with `allocator`.
// On failure nothing is leaked and the error is returned.
ops_copy :: proc(ops: []Operation, allocator := context.allocator) -> ([]Operation, errs.Error) {
	if len(ops) == 0 {
		return {}, {}
	}
	out := make([dynamic]Operation, allocator)
	if aerr := reserve(&out, len(ops)); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"txn: reserving the %v-operation log copy failed: %v",
			len(ops),
			aerr,
			allocator = allocator,
		)
	}
	resize(&out, len(ops))
	for op, i in ops {
		switch o in op {
		case Insert:
			data, derr := bytes_clone(o.data, allocator)
			if !errs.ok(derr) {
				ops_destroy_partial(out[:i], allocator)
				delete(out)
				return {}, derr
			}
			out[i] = Operation(Insert{pos = o.pos, data = data})
		case Delete:
			out[i] = Operation(Delete{range = o.range})
		case Replace:
			data, derr := bytes_clone(o.data, allocator)
			if !errs.ok(derr) {
				ops_destroy_partial(out[:i], allocator)
				delete(out)
				return {}, derr
			}
			out[i] = Operation(Replace{range = o.range, data = data})
		}
	}
	return out[:], {}
}

// bytes_clone copies `data` with `allocator` (empty data stays empty).
bytes_clone :: proc(data: []byte, allocator := context.allocator) -> ([]byte, errs.Error) {
	if len(data) == 0 {
		return {}, {}
	}
	out, aerr := mem.alloc_bytes(len(data), 1, allocator)
	if aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"txn: allocating %v bytes for an operation copy failed: %v",
			len(data),
			aerr,
			allocator = allocator,
		)
	}
	copy(out, data)
	return out, {}
}

// ops_destroy_partial frees the copied data of the entries (used when
// a later copy fails).
ops_destroy_partial :: proc(ops: []Operation, allocator := context.allocator) {
	for op in ops {
		switch o in op {
		case Insert:
			mem.free(raw_data(o.data), allocator)
		case Delete:
		case Replace:
			mem.free(raw_data(o.data), allocator)
		}
	}
}

// ops_destroy frees an owned operation copy.
ops_destroy :: proc(ops: []Operation) {
	for op in ops {
		switch o in op {
		case Insert:
			delete(o.data)
		case Delete:
		case Replace:
			delete(o.data)
		}
	}
	delete(ops)
}
