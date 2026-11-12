// Persistent copy-on-write rope tree (M02.03), in package rope on top
// of the M02.01 chunk store and the M02.02 piece/metrics model.
//
// ```text
// Node (leaf)       pieces + local metrics   (the M02.02 Leaf payload)
// Node (internal)   children + cumulative metrics
// Tree              root (nil = empty) + revision
// ```
//
// Structure (SPECS.md §7.1: Internal node / RopeRoot):
//
// - **B-tree shape.** Leaves hold 1..MAX_PIECES_PER_LEAF pieces and at
//   most `target_leaf_bytes` bytes (a single oversized piece gets its
//   own leaf). Internal nodes hold up to MAX_CHILDREN (8) children;
//   non-root internal nodes hold at least MIN_CHILDREN (4); the root
//   holds 2..8 or is a leaf. All leaves sit at one depth. Node
//   metrics are folded with `combine` from children/pieces.
// - **Persistence (copy-on-write).** Mutations never modify existing
//   nodes: the affected path is rebuilt with new nodes, unchanged
//   subtrees are shared by pointer. A captured old root therefore
//   stays byte-identical across any number of later edits; read it
//   with `tree_read_root`. Nodes are pool-allocated and never
//   recycled while any root references them — every node lives until
//   `tree_destroy` (retention/pruning policy is M02.07/M02.08's
//   concern; do not `pool.put` nodes).
// - **Revision.** Every successful mutation bumps `revision`;
//   no-ops (empty data, empty range) and failed operations do not.
// - **Balancing.** Inserts split over-full leaves (at the piece
//   level) and over-full internal nodes (halving); the cascade may
//   grow the root, rebuilt bottom-up with balanced chunking so leaf
//   depth stays uniform. Deletes remove covered pieces (splitting
//   boundary pieces), drop emptied leaves, and merge under-full
//   internal children with a sibling until the minimum holds; a root
//   internal with one child collapses into it.
// - **Ownership.** The node pool (`core:container/pool`, intrusive
//   `link` field, virtual-arena backed) owns every node;
//   `tree_destroy` releases it wholesale. Working lists and error
//   messages use the caller-provided allocator of each operation —
//   never the tree's storage, so they cannot fail together with it.
// - **Single owner.** Not thread-safe; one mutator thread (AGENTS.md
//   §13). Old roots may be read from that thread (or others that do
//   not mutate the store) while the tree is not destroyed.
//
// Backend-free: imports only `core:` packages plus `core/chunk` and
// `core/errs` — no Sokol collection (SPECS.md §4.2), builds under
// `-no-crt`.
package rope

import pool "core:container/pool"
import "core:mem"

import chunk "../chunk"
import errs "../errs"

// MAX_CHILDREN is the branching bound of internal nodes.
MAX_CHILDREN :: 8

// MIN_CHILDREN is the minimum child count of a non-root internal node
// (half of MAX_CHILDREN; merges restore it after deletes).
MIN_CHILDREN :: 4

// MAX_TREE_DEPTH bounds the span-iterator stack (far above any real
// tree: height ~ log_8(nodes)).
MAX_TREE_DEPTH :: 64

// Node_Kind tags a node's payload.
Node_Kind :: enum u8 {
	Leaf,
	Internal,
}

// Node is one pool-allocated rope node: either a leaf (pieces +
// metrics) or an internal node (children + metrics). Both payloads are
// inline (one size for the pool); the unused payload is wasted space,
// deliberately traded for boring, type-safe access. The intrusive
// `link` field is the pool's free-list link (pool.init(&p, "link")).
Node :: struct {
	link:    ^Node,
	kind:    Node_Kind,
	metrics: Metrics,
	// Leaf payload.
	pieces:      [MAX_PIECES_PER_LEAF]Piece,
	piece_count: int,
	// Internal payload.
	children:    [MAX_CHILDREN]^Node,
	child_count: int,
}

// Tree is a persistent rope: a root node plus a revision counter.
// Contains a pool with internal locks; treat it as a fixed-location
// value — pass by pointer, never by value.
Tree :: struct {
	store:    ^chunk.Store, // borrowed; must outlive the tree
	target:   int, // target leaf content size
	pool:     pool.Pool(Node),
	root:     ^Node, // nil = empty
	revision: u64, // bumped by every successful mutation
}

// Stack_Frame is one level of the span iterator's descent stack.
Stack_Frame :: struct {
	node:  ^Node,
	child: int,
}

// Tree_Span_Iter walks the pieces of a byte range of a snapshot root,
// piece by piece. Spans are borrowed slices of immutable chunk
// storage.
Tree_Span_Iter :: struct {
	stack:     [MAX_TREE_DEPTH]Stack_Frame,
	depth:     int,
	leaf:      ^Node, // current leaf; nil = done
	piece:     int,
	off_piece: int,
	remaining: int,
}

// tree_init prepares `tree` as an empty rope over `store`.
// `options.target_leaf_bytes` must be non-negative (asserted); 0
// selects the default. The tree itself stores nothing with the caller
// allocator (the pool is self-owned); `allocator` backs error messages
// only.
tree_init :: proc(
	tree: ^Tree,
	store: ^chunk.Store,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	assert(store != nil, "rope: nil chunk store")
	assert(options.target_leaf_bytes >= 0, "rope: negative target_leaf_bytes")
	tree.store = store
	tree.target = options.target_leaf_bytes if options.target_leaf_bytes > 0 else DEFAULT_TARGET_LEAF_BYTES
	tree.root = nil
	tree.revision = 0
	if aerr := pool.init(&tree.pool, "link"); aerr != .None {
		return errs.newf(
			.Resource_Limit,
			"rope: node pool init failed: %v",
			aerr,
			allocator = allocator,
		)
	}
	return {}
}

// tree_destroy releases the tree: the pool's node storage wholesale
// (individual frees are unnecessary; nodes are never recycled).
// Destroy after every borrowed span and snapshot root is done.
tree_destroy :: proc(tree: ^Tree) {
	pool.destroy(&tree.pool)
	tree^ = Tree{}
}

// tree_append stores `data` at the end of the tree (== insert at
// byte_count). Empty data is a no-op (no revision bump).
tree_append :: proc(tree: ^Tree, data: []byte, allocator := context.allocator) -> errs.Error {
	return tree_insert(tree, tree_byte_count(tree), data, allocator)
}

// tree_insert stores `data` at byte offset `offset` (0..=byte_count).
// The inserted content is interned in the chunk store (split at the
// store's chunk size) and spliced as pieces; a piece containing the
// offset is split first. Empty data is a no-op; an out-of-range offset
// is `.Invalid_Input`; allocation failures are `.Resource_Limit` and
// leave the tree untouched. Success bumps the revision.
tree_insert :: proc(tree: ^Tree, offset: int, data: []byte, allocator := context.allocator) -> errs.Error {
	if len(data) == 0 {
		return {}
	}
	if offset < 0 || offset > tree_byte_count(tree) {
		return errs.newf(
			.Invalid_Input,
			"rope: insert offset %v outside [0, %v]",
			offset,
			tree_byte_count(tree),
			allocator = allocator,
		)
	}

	ids, cerr := chunk.insert(tree.store, data, allocator)
	if !errs.ok(cerr) {
		return cerr
	}
	defer delete(ids)

	pieces := make([dynamic]Piece, allocator)
	defer delete(pieces)
	if aerr := reserve(&pieces, len(ids)); aerr != .None {
		return errs.newf(
			.Resource_Limit,
			"rope: reserving the %v-piece list failed: %v",
			len(ids),
			aerr,
			allocator = allocator,
		)
	}
	for id in ids {
		d := chunk.data(tree.store, id)
		append(&pieces, Piece{store_id = id, byte_start = 0, byte_length = len(d)})
	}

	new_root: ^Node
	if tree.root == nil {
		leaves, lerr := pack_leaves(tree, pieces[:], allocator)
		if !errs.ok(lerr) {
			return lerr
		}
		defer delete(leaves)
		new_root, lerr = pack_nodes(tree, leaves[:], allocator)
		if !errs.ok(lerr) {
			return lerr
		}
	} else {
		repl, ierr := insert_at(tree, tree.root, offset, pieces[:], allocator)
		if !errs.ok(ierr) {
			return ierr
		}
		defer delete(repl)
		new_root, ierr = pack_nodes(tree, repl[:], allocator)
		if !errs.ok(ierr) {
			return ierr
		}
	}
	tree.root = new_root
	tree.revision += 1
	return {}
}

// tree_delete removes the byte range `range` (start inclusive, end
// exclusive) from the tree. Boundary pieces are split; emptied leaves
// are dropped; under-full internal children merge with a sibling.
// An empty range is a no-op; an out-of-range range is `.Invalid_Input`
// and leaves the tree untouched. Success bumps the revision.
tree_delete :: proc(tree: ^Tree, range: Byte_Range, allocator := context.allocator) -> errs.Error {
	total := 0 if tree.root == nil else tree.root.metrics.byte_count
	if range.start < 0 || range.end < range.start || range.end > total {
		return errs.newf(
			.Invalid_Input,
			"rope: delete range [%v, %v) outside [0, %v]",
			range.start,
			range.end,
			total,
			allocator = allocator,
		)
	}
	if range.start == range.end {
		return {}
	}

	repl, derr := delete_at(tree, tree.root, range.start, range.end - range.start, allocator)
	if !errs.ok(derr) {
		return derr
	}
	defer delete(repl)

	switch len(repl) {
	case 0:
		tree.root = nil
	case 1:
		tree.root = repl[0]
		if repl[0].kind == .Internal && repl[0].child_count == 1 {
			tree.root = repl[0].children[0]
		}
	case:
		new_root, perr := pack_nodes(tree, repl[:], allocator)
		if !errs.ok(perr) {
			return perr
		}
		tree.root = new_root
	}
	tree.revision += 1
	return {}
}

// tree_read copies bytes from `range` into `out` (up to len(out)),
// reading from the current root. Partial fills are not errors.
tree_read :: proc(
	tree: ^Tree,
	range: Byte_Range,
	out: []byte,
	allocator := context.allocator,
) -> (int, errs.Error) {
	return tree_read_root(tree, tree.root, range, out, allocator)
}

// tree_read_root is `tree_read` from a captured snapshot root: roots
// of earlier revisions stay valid and byte-identical across later
// edits (persistence contract).
tree_read_root :: proc(
	tree: ^Tree,
	root: ^Node,
	range: Byte_Range,
	out: []byte,
	allocator := context.allocator,
) -> (int, errs.Error) {
	it: Tree_Span_Iter
	if ierr := tree_span_iter_init(&it, root, range, allocator); !errs.ok(ierr) {
		return 0, ierr
	}
	n := 0
	for n < len(out) {
		span, more := tree_span_iter_next(&it, tree)
		if !more {
			break
		}
		c := min(len(span), len(out) - n)
		copy(out[n:], span[:c])
		n += c
		if c < len(span) {
			break // out is full mid-span
		}
	}
	return n, {}
}

// tree_read_all copies the whole `range` of the current root into a
// fresh buffer allocated with `allocator` (caller-owned).
tree_read_all :: proc(
	tree: ^Tree,
	range: Byte_Range,
	allocator := context.allocator,
) -> ([]byte, errs.Error) {
	return tree_read_root_all(tree, tree.root, range, allocator)
}

// tree_read_root_all is `tree_read_all` from a captured snapshot root.
tree_read_root_all :: proc(
	tree: ^Tree,
	root: ^Node,
	range: Byte_Range,
	allocator := context.allocator,
) -> ([]byte, errs.Error) {
	total := 0 if root == nil else root.metrics.byte_count
	if range.start < 0 || range.end < range.start || range.end > total {
		return {}, errs.newf(
			.Invalid_Input,
			"rope: range [%v, %v) outside [0, %v]",
			range.start,
			range.end,
			total,
			allocator = allocator,
		)
	}
	n := range.end - range.start
	out, aerr := mem.alloc_bytes(n, 1, allocator)
	if aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: allocating %v bytes for a read failed: %v",
			n,
			aerr,
			allocator = allocator,
		)
	}
	copied, rerr := tree_read_root(tree, root, range, out, allocator)
	if !errs.ok(rerr) {
		mem.free(raw_data(out), allocator)
		return {}, rerr
	}
	return out[:copied], {}
}

// tree_metrics returns the current root's total metrics (zero for an
// empty tree).
tree_metrics :: proc(tree: ^Tree) -> Metrics {
	if tree.root == nil {
		return {}
	}
	return tree.root.metrics
}

// tree_byte_count returns the current content length in bytes.
tree_byte_count :: proc(tree: ^Tree) -> int {
	if tree.root == nil {
		return 0
	}
	return tree.root.metrics.byte_count
}

// tree_revision returns the mutation counter.
tree_revision :: proc(tree: ^Tree) -> u64 {
	return tree.revision
}

// tree_node_count returns the number of live nodes (pool outstanding).
tree_node_count :: proc(tree: ^Tree) -> int {
	return pool.num_outstanding(&tree.pool)
}

// tree_leaf_count returns the number of leaf nodes.
tree_leaf_count :: proc(tree: ^Tree) -> int {
	count := 0
	count_leaves(tree.root, &count)
	return count
}

// tree_height returns the tree height (0 = empty, 1 = leaf root).
tree_height :: proc(tree: ^Tree) -> int {
	h := 0
	for n := tree.root; n != nil; n = n.children[0] if n.kind == .Internal else nil {
		h += 1
	}
	return h
}

// tree_check validates every invariant of the current tree and returns
// `.Internal` naming the first violation: node bounds (pieces, bytes,
// child counts), uniform leaf depth, piece validity against the chunk
// store, and exact metric recomputation. `allocator` backs the error
// message.
tree_check :: proc(tree: ^Tree, allocator := context.allocator) -> errs.Error {
	if tree.root == nil {
		return {}
	}
	_, cerr := check_node(tree, tree.root, true, allocator)
	return cerr
}

// tree_span_iter_init validates `range` against the snapshot `root`
// and positions the iterator at its start. An empty range yields an
// iterator that immediately reports done.
tree_span_iter_init :: proc(
	it: ^Tree_Span_Iter,
	root: ^Node,
	range: Byte_Range,
	allocator := context.allocator,
) -> errs.Error {
	it^ = Tree_Span_Iter{}
	total := 0 if root == nil else root.metrics.byte_count
	if range.start < 0 || range.end < range.start || range.end > total {
		return errs.newf(
			.Invalid_Input,
			"rope: range [%v, %v) outside [0, %v]",
			range.start,
			range.end,
			total,
			allocator = allocator,
		)
	}
	it.remaining = range.end - range.start
	if it.remaining == 0 {
		return {}
	}

	// Descend to the leaf containing range.start, pushing the path.
	n := root
	pos := range.start
	for n.kind == .Internal {
		idx := 0
		for idx < n.child_count - 1 && pos >= n.children[idx].metrics.byte_count {
			pos -= n.children[idx].metrics.byte_count
			idx += 1
		}
		assert(it.depth < MAX_TREE_DEPTH, "rope: tree deeper than the iterator stack")
		it.stack[it.depth] = Stack_Frame{node = n, child = idx}
		it.depth += 1
		n = n.children[idx]
	}
	it.leaf = n
	it.piece, it.off_piece = piece_at(n, pos)
	return {}
}

// tree_span_iter_next returns the next span of the range (a slice of
// chunk storage) and whether one exists. Spans never exceed the
// requested range and never cross piece boundaries.
tree_span_iter_next :: proc(it: ^Tree_Span_Iter, tree: ^Tree) -> (span: []byte, more: bool) {
	for {
		if it.remaining == 0 || it.leaf == nil {
			return {}, false
		}
		if it.piece < it.leaf.piece_count {
			p := it.leaf.pieces[it.piece]
			cd := chunk.data(tree.store, p.store_id)
			n := min(it.remaining, p.byte_length - it.off_piece)
			span = cd[p.byte_start + it.off_piece:p.byte_start + it.off_piece + n]
			it.remaining -= n
			it.off_piece += n
			if it.off_piece == p.byte_length {
				it.off_piece = 0
				it.piece += 1
			}
			return span, true
		}
		// Leaf exhausted: advance to the next leaf via the stack.
		it.leaf = nil
		for it.depth > 0 {
			frame := &it.stack[it.depth - 1]
			frame.child += 1
			if frame.child < frame.node.child_count {
				n := frame.node.children[frame.child]
				for n.kind == .Internal {
					assert(it.depth < MAX_TREE_DEPTH, "rope: tree deeper than the iterator stack")
					it.stack[it.depth] = Stack_Frame{node = n, child = 0}
					it.depth += 1
					n = n.children[0]
				}
				it.leaf = n
				it.piece = 0
				it.off_piece = 0
				break
			}
			it.depth -= 1
		}
	}
}

// alloc_node takes a fresh (zeroed) node of the given kind from the
// pool.
alloc_node :: proc(tree: ^Tree, kind: Node_Kind, allocator := context.allocator) -> (^Node, errs.Error) {
	n, aerr := pool.get(&tree.pool)
	if aerr != .None {
		return nil, errs.newf(
			.Resource_Limit,
			"rope: allocating a tree node failed: %v",
			aerr,
			allocator = allocator,
		)
	}
	n.kind = kind
	return n, {}
}

// fill_leaf writes `pieces` into a fresh leaf node and computes its
// metrics.
fill_leaf :: proc(tree: ^Tree, n: ^Node, pieces: []Piece) {
	n.kind = .Leaf
	n.piece_count = len(pieces)
	m := Metrics{}
	for p, i in pieces {
		n.pieces[i] = p
		cd := chunk.data(tree.store, p.store_id)
		m = combine(m, metrics_of(cd[p.byte_start:p.byte_start + p.byte_length]))
	}
	n.metrics = m
}

// fill_internal writes `children` into a fresh internal node and
// computes its metrics.
fill_internal :: proc(n: ^Node, children: []^Node) {
	n.kind = .Internal
	n.child_count = len(children)
	m := Metrics{}
	for c, i in children {
		n.children[i] = c
		m = combine(m, c.metrics)
	}
	n.metrics = m
}

// piece_at returns the piece of a leaf containing byte offset `pos`
// (0..=leaf bytes) and the offset within it. pos == leaf byte count
// returns (piece_count, 0).
piece_at :: proc(n: ^Node, pos: int) -> (idx, off: int) {
	p := pos
	for i := 0; i < n.piece_count; i += 1 {
		if p < n.pieces[i].byte_length {
			return i, p
		}
		p -= n.pieces[i].byte_length
	}
	return n.piece_count, 0
}

// leaf_full_for reports whether appending a piece would overflow a
// leaf's capacity (piece count or byte bound; an empty leaf always
// accepts its first piece).
leaf_full_for :: proc(tree: ^Tree, n: ^Node, p: Piece) -> bool {
	if n.piece_count >= MAX_PIECES_PER_LEAF {
		return true
	}
	return n.piece_count > 0 && n.metrics.byte_count + p.byte_length > tree.target
}

// node_list builds a small caller-owned node list (for 1..2-node
// replacement results).
node_list :: proc(nodes: ..^Node, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	out := make([dynamic]^Node, allocator)
	if aerr := reserve(&out, len(nodes)); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: allocating a %v-node list failed: %v",
			len(nodes),
			aerr,
			allocator = allocator,
		)
	}
	append(&out, ..nodes)
	return out, {}
}

// pack_leaves packs `pieces` into new leaf nodes respecting the piece
// count and byte bounds. Returns at least one leaf (pieces is
// non-empty).
pack_leaves :: proc(tree: ^Tree, pieces: []Piece, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	leaves := make([dynamic]^Node, allocator)
	for p in pieces {
		last := len(leaves) - 1
		if last < 0 || leaf_full_for(tree, leaves[last], p) {
			n, nerr := alloc_node(tree, .Leaf, allocator)
			if !errs.ok(nerr) {
				delete(leaves)
				return {}, nerr
			}
			append(&leaves, n)
			last += 1
		}
		n := leaves[last]
		cd := chunk.data(tree.store, p.store_id)
		n.pieces[n.piece_count] = p
		n.piece_count += 1
		n.metrics = combine(n.metrics, metrics_of(cd[p.byte_start:p.byte_start + p.byte_length]))
	}
	return leaves, {}
}

// chunk_children packs a child sequence into new internal nodes with
// balanced chunk sizes: one node for <= MAX_CHILDREN children,
// otherwise ceil(total/MAX_CHILDREN) nodes each holding total/n or
// total/n+1 children (>= MIN_CHILDREN).
chunk_children :: proc(tree: ^Tree, children: []^Node, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	out := make([dynamic]^Node, allocator)
	if len(children) == 0 {
		return out, {}
	}
	total := len(children)
	n_chunks := (total + MAX_CHILDREN - 1) / MAX_CHILDREN
	base := total / n_chunks
	extra := total % n_chunks
	start := 0
	for c in 0 ..< n_chunks {
		size := base + (1 if c < extra else 0)
		n, nerr := alloc_node(tree, .Internal, allocator)
		if !errs.ok(nerr) {
			delete(out)
			return {}, nerr
		}
		fill_internal(n, children[start:start + size])
		append(&out, n)
		start += size
	}
	return out, {}
}

// pack_nodes builds a tree from a list of same-depth nodes (the result
// of a root-level splice): groups them into internal nodes level by
// level until one root remains. Empty list -> nil; single node ->
// itself.
pack_nodes :: proc(tree: ^Tree, nodes: []^Node, allocator := context.allocator) -> (^Node, errs.Error) {
	if len(nodes) == 0 {
		return nil, {}
	}
	cur := make([dynamic]^Node, allocator)
	defer delete(cur)
	if aerr := reserve(&cur, len(nodes)); aerr != .None {
		return nil, errs.newf(
			.Resource_Limit,
			"rope: reserving the %v-node pack list failed: %v",
			len(nodes),
			aerr,
			allocator = allocator,
		)
	}
	append(&cur, ..nodes)
	for len(cur) > 1 {
		next, nerr := chunk_children(tree, cur[:], allocator)
		if !errs.ok(nerr) {
			return nil, nerr
		}
		delete(cur)
		cur = next
	}
	return cur[0], {}
}

// insert_at inserts `pieces` at byte offset `pos` relative to node `n`
// (which is NOT modified) and returns the list of replacement nodes
// for `n` at its level (same depth): packed leaves for a leaf `n`,
// repacked internal nodes for an internal `n`.
insert_at :: proc(tree: ^Tree, n: ^Node, pos: int, pieces: []Piece, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	if n.kind == .Leaf {
		return insert_into_leaf(tree, n, pos, pieces, allocator)
	}

	idx := 0
	p := pos
	for idx < n.child_count - 1 && p >= n.children[idx].metrics.byte_count {
		p -= n.children[idx].metrics.byte_count
		idx += 1
	}
	child_repl, cerr := insert_at(tree, n.children[idx], p, pieces, allocator)
	if !errs.ok(cerr) {
		return {}, cerr
	}
	defer delete(child_repl)

	seq := make([dynamic]^Node, allocator)
	defer delete(seq)
	total := n.child_count - 1 + len(child_repl)
	if aerr := reserve(&seq, total); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: reserving the %v-child splice failed: %v",
			total,
			aerr,
			allocator = allocator,
		)
	}
	append(&seq, ..n.children[:idx])
	append(&seq, ..child_repl[:])
	append(&seq, ..n.children[idx + 1:n.child_count])
	return chunk_children(tree, seq[:], allocator)
}

// insert_into_leaf splices `pieces` into leaf `n` at byte offset `pos`
// (splitting the boundary piece when pos falls inside it) and packs
// the resulting piece sequence into new leaves. `n` is NOT modified.
insert_into_leaf :: proc(tree: ^Tree, n: ^Node, pos: int, pieces: []Piece, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	seq := make([dynamic]Piece, allocator)
	defer delete(seq)
	total := n.piece_count + len(pieces) + 1
	if aerr := reserve(&seq, total); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: reserving the %v-piece splice failed: %v",
			total,
			aerr,
			allocator = allocator,
		)
	}

	idx, off := piece_at(n, pos)
	append(&seq, ..n.pieces[:idx])
	if off > 0 {
		p := n.pieces[idx]
		append(&seq, Piece{store_id = p.store_id, byte_start = p.byte_start, byte_length = off})
	}
	append(&seq, ..pieces)
	if off > 0 {
		p := n.pieces[idx]
		append(&seq, Piece{store_id = p.store_id, byte_start = p.byte_start + off, byte_length = p.byte_length - off})
	}
	start := idx + 1 if off > 0 else idx
	append(&seq, ..n.pieces[start:n.piece_count])
	return pack_leaves(tree, seq[:], allocator)
}

// delete_at removes `length` bytes starting at byte offset `pos`
// relative to node `n` (which is NOT modified) and returns the list of
// replacement nodes for `n` at its level: 0 (fully removed), 1, or 2
// for leaves; repacked and rebalanced internal nodes otherwise.
delete_at :: proc(tree: ^Tree, n: ^Node, pos, length: int, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	if n.kind == .Leaf {
		survivors: [MAX_PIECES_PER_LEAF + 1]Piece
		count := leaf_delete_survivors(n, pos, length, survivors[:])
		if count == 0 {
			return make([dynamic]^Node, allocator), {}
		}
		if count <= MAX_PIECES_PER_LEAF {
			n2, nerr := alloc_node(tree, .Leaf, allocator)
			if !errs.ok(nerr) {
				return {}, nerr
			}
			fill_leaf(tree, n2, survivors[:count])
			return node_list(n2, allocator = allocator)
		}
		// Same-piece splits can leave MAX+1 survivors: split in half.
		mid := count / 2
		left, lerr := alloc_node(tree, .Leaf, allocator)
		if !errs.ok(lerr) {
			return {}, lerr
		}
		right, rerr := alloc_node(tree, .Leaf, allocator)
		if !errs.ok(rerr) {
			return {}, rerr
		}
		fill_leaf(tree, left, survivors[:mid])
		fill_leaf(tree, right, survivors[mid:count])
		return node_list(left, right, allocator = allocator)
	}

	// Internal: splice child replacements into a fresh sequence.
	seq := make([dynamic]^Node, allocator)
	defer delete(seq)
	if aerr := reserve(&seq, n.child_count); aerr != .None {
		return {}, errs.newf(
			.Resource_Limit,
			"rope: reserving the %v-child list failed: %v",
			n.child_count,
			aerr,
			allocator = allocator,
		)
	}
	append(&seq, ..n.children[:n.child_count])

	idx := 0
	rel := pos
	remaining := length
	for idx < n.child_count - 1 && rel >= n.children[idx].metrics.byte_count {
		rel -= n.children[idx].metrics.byte_count
		idx += 1
	}
	for remaining > 0 && idx < len(seq) {
		child := seq[idx]
		take := min(remaining, child.metrics.byte_count - rel)
		repl, derr := delete_at(tree, child, rel, take, allocator)
		if !errs.ok(derr) {
			return {}, derr
		}
		remove_range(&seq, idx, idx + 1)
		if len(repl) > 0 {
			ok, aerr := inject_at_elems(&seq, idx, ..repl[:])
			if !ok {
				delete(repl)
				return {}, errs.newf(
					.Resource_Limit,
					"rope: splicing %v child replacements failed: %v",
					len(repl),
					aerr,
					allocator = allocator,
				)
			}
		}
		remaining -= take
		idx += len(repl)
		delete(repl)
		rel = 0
	}

	if err := rebalance_seq(tree, &seq, allocator); !errs.ok(err) {
		return {}, err
	}
	return chunk_children(tree, seq[:], allocator)
}

// rebalance_seq merges under-full internal children (fewer than
// MIN_CHILDREN) with a sibling until the minimum holds, as long as
// more than one child remains. Leaves have no minimum and are left
// alone.
rebalance_seq :: proc(tree: ^Tree, seq: ^[dynamic]^Node, allocator := context.allocator) -> errs.Error {
	for {
		fixed := true
		for i in 0 ..< len(seq) {
			child := seq[i]
			if len(seq) > 1 && child.kind == .Internal && child.child_count < MIN_CHILDREN {
				j := i + 1 if i + 1 < len(seq) else i - 1
				lo := min(i, j)
				hi := max(i, j) + 1
				// Document order: left sibling first, regardless of
				// which one was under-full.
				merged, merr := merge_siblings(tree, seq[lo], seq[hi - 1], allocator)
				if !errs.ok(merr) {
					return merr
				}
				remove_range(seq, lo, hi)
				if len(merged) > 0 {
					ok, aerr := inject_at_elems(seq, lo, ..merged[:])
					if !ok {
						delete(merged)
						return errs.newf(
							.Resource_Limit,
							"rope: splicing a merge result failed: %v",
							aerr,
							allocator = allocator,
						)
					}
				}
				delete(merged)
				fixed = false
				break
			}
		}
		if fixed {
			return {}
		}
	}
}

// merge_siblings combines the children of two adjacent internal nodes
// into one or two new nodes (one when the sum fits MAX_CHILDREN, two
// balanced halves otherwise). Both inputs are left untouched.
merge_siblings :: proc(tree: ^Tree, a, b: ^Node, allocator := context.allocator) -> ([dynamic]^Node, errs.Error) {
	total := a.child_count + b.child_count
	if total <= MAX_CHILDREN {
		n, nerr := alloc_node(tree, .Internal, allocator)
		if !errs.ok(nerr) {
			return {}, nerr
		}
		children: [MAX_CHILDREN]^Node
		for c, i in a.children[:a.child_count] {
			children[i] = c
		}
		for c, i in b.children[:b.child_count] {
			children[a.child_count + i] = c
		}
		fill_internal(n, children[:total])
		return node_list(n, allocator = allocator)
	}
	left, lerr := alloc_node(tree, .Internal, allocator)
	if !errs.ok(lerr) {
		return {}, lerr
	}
	right, rerr := alloc_node(tree, .Internal, allocator)
	if !errs.ok(rerr) {
		return {}, rerr
	}
	left_count := (total + 1) / 2
	children: [MAX_CHILDREN * 2]^Node
	for c, i in a.children[:a.child_count] {
		children[i] = c
	}
	for c, i in b.children[:b.child_count] {
		children[a.child_count + i] = c
	}
	fill_internal(left, children[:left_count])
	fill_internal(right, children[left_count:total])
	return node_list(left, right, allocator = allocator)
}

// leaf_delete_survivors computes the pieces surviving the deletion of
// [pos, pos+length) from leaf `n` (boundary pieces split) into `out`
// (room for MAX_PIECES_PER_LEAF+1 entries) and returns the count.
leaf_delete_survivors :: proc(n: ^Node, pos, length: int, out: []Piece) -> int {
	s_idx, s_off := piece_at(n, pos)
	e_idx, e_off := piece_at(n, pos + length)

	count := 0
	for i := 0; i < s_idx; i += 1 {
		out[count] = n.pieces[i]
		count += 1
	}
	if s_off > 0 {
		p := n.pieces[s_idx]
		out[count] = Piece{store_id = p.store_id, byte_start = p.byte_start, byte_length = s_off}
		count += 1
	}
	if e_idx < n.piece_count && e_off > 0 {
		p := n.pieces[e_idx]
		out[count] = Piece{store_id = p.store_id, byte_start = p.byte_start + e_off, byte_length = p.byte_length - e_off}
		count += 1
		for i := e_idx + 1; i < n.piece_count; i += 1 {
			out[count] = n.pieces[i]
			count += 1
		}
	} else {
		for i := e_idx; i < n.piece_count; i += 1 {
			out[count] = n.pieces[i]
			count += 1
		}
	}
	return count
}

// check_node validates `n` and its subtree, returning its leaf depth.
// See `tree_check` for the invariants.
check_node :: proc(tree: ^Tree, n: ^Node, is_root: bool, allocator := context.allocator) -> (int, errs.Error) {
	switch n.kind {
	case .Leaf:
		if n.piece_count < 1 {
			return 0, errs.newf(.Internal, "rope: leaf with no pieces", allocator = allocator)
		}
		if n.piece_count > MAX_PIECES_PER_LEAF {
			return 0, errs.newf(
				.Internal,
				"rope: leaf with %v pieces (max %v)",
				n.piece_count,
				MAX_PIECES_PER_LEAF,
				allocator = allocator,
			)
		}
		if n.piece_count > 1 && n.metrics.byte_count > tree.target {
			return 0, errs.newf(
				.Internal,
				"rope: leaf with %v bytes (target %v)",
				n.metrics.byte_count,
				tree.target,
				allocator = allocator,
			)
		}
		m := Metrics{}
		for i in 0 ..< n.piece_count {
			p := n.pieces[i]
			cd, found := chunk.lookup(tree.store, p.store_id)
			if !found {
				return 0, errs.newf(
					.Internal,
					"rope: piece references unknown chunk id %v",
					p.store_id,
					allocator = allocator,
				)
			}
			if p.byte_length <= 0 || p.byte_start < 0 || p.byte_start + p.byte_length > len(cd) {
				return 0, errs.newf(
					.Internal,
					"rope: piece range [%v, %v) outside chunk length %v",
					p.byte_start,
					p.byte_start + p.byte_length,
					len(cd),
					allocator = allocator,
				)
			}
			m = combine(m, metrics_of(cd[p.byte_start:p.byte_start + p.byte_length]))
		}
		if m != n.metrics {
			return 0, errs.newf(.Internal, "rope: leaf metrics mismatch", allocator = allocator)
		}
		return 1, {}

	case .Internal:
		if is_root {
			if n.child_count < 2 || n.child_count > MAX_CHILDREN {
				return 0, errs.newf(
					.Internal,
					"rope: root with %v children (expected 2..%v)",
					n.child_count,
					MAX_CHILDREN,
					allocator = allocator,
				)
			}
		} else if n.child_count < MIN_CHILDREN || n.child_count > MAX_CHILDREN {
			return 0, errs.newf(
				.Internal,
				"rope: internal node with %v children (expected %v..%v)",
				n.child_count,
				MIN_CHILDREN,
				MAX_CHILDREN,
				allocator = allocator,
			)
		}
		m := Metrics{}
		depth := -1
		for i in 0 ..< n.child_count {
			child := n.children[i]
			if child == nil {
				return 0, errs.newf(.Internal, "rope: nil child", allocator = allocator)
			}
			d, cerr := check_node(tree, child, false, allocator)
			if !errs.ok(cerr) {
				return 0, cerr
			}
			if depth == -1 {
				depth = d
			} else if d != depth {
				return 0, errs.newf(
					.Internal,
					"rope: leaf depth mismatch (%v vs %v)",
					d,
					depth,
					allocator = allocator,
				)
			}
			m = combine(m, child.metrics)
		}
		if m != n.metrics {
			return 0, errs.newf(.Internal, "rope: internal metrics mismatch", allocator = allocator)
		}
		return depth + 1, {}
	}
	return 0, errs.newf(.Internal, "rope: unknown node kind", allocator = allocator)
}

// count_leaves walks a subtree counting leaf nodes.
count_leaves :: proc(n: ^Node, count: ^int) {
	if n == nil {
		return
	}
	if n.kind == .Leaf {
		count^ += 1
		return
	}
	for i in 0 ..< n.child_count {
		count_leaves(n.children[i], count)
	}
}
