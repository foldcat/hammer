// Coordinate conversion over the rope tree (M02.04), in package rope.
//
// SPECS.md §7.3 distinguishes byte offsets, Unicode scalar offsets,
// and logical line/column positions; they are not interchangeable, so
// the conversions here use distinct index types (`Scalar_Index`,
// `Line_Index`, `Column_Index`) — byte offsets remain the rope's
// native plain-int coordinate (AGENTS.md §14.3). Every conversion goes
// through this module.
//
// Semantics:
//
// - **Bytes** are UTF-8 byte offsets into the tree content, 0..=total.
// - **Scalars** index Unicode scalars by the counting model of
//   `metrics_of` (M02.02): a lead C2..DF/E0..EF/F0..F4 with its
//   continuations is one scalar, every other byte one scalar. A byte
//   position inside a multi-byte scalar maps to that scalar's index;
//   `scalar_to_byte` returns the scalar's first byte.
// - **Lines** are separated by line breaks — each LF and each lone CR
//   (a CRLF pair is one break, per `line_break_count`). Line N spans
//   from after break N-1 (or byte 0) through its break; `line_count`
//   is `line_break_count + 1` (an empty text has one empty line).
//   `line_start(N)` is the first byte of line N; `line_end(N)` is the
//   byte just past its break (== `line_start(N+1)`, or `total` for
//   the last line).
// - **Columns** count scalars from the line start (plan9 rune
//   semantics), 0-based.
//
// Grapheme cursor positions are deliberately absent: Unicode grapheme
// rules need segmentation context (SPECS.md §7.2) and are owned by
// M05.02. Coordinates are over the current root; all inputs are
// bounds-validated (`.Invalid_Input`), and reads never flatten — each
// conversion descends O(depth) with metric folds and decodes at most
// one piece (the chunk size).
package rope

import chunk "../chunk"
import errs "../errs"

// Scalar_Index is a Unicode scalar offset (0..=scalar_count).
Scalar_Index :: distinct int

// Line_Index is a 0-based line number (0..=line_break_count).
Line_Index :: distinct int

// Column_Index is a 0-based scalar column within a line.
Column_Index :: distinct int

// Coord_Cursor is the shared forward-walk state for conversions: the
// scalar decode position, the pending multi-byte-scalar state, and the
// resolved line-break count with the provisional CR carry. It matches
// `metrics_of`/`combine` exactly, so a cursor derived from folded
// metrics continues the walk seamlessly.
Coord_Cursor :: struct {
	// scalar is the index of the next scalar to start — or of the
	// open scalar when `pending > 0`.
	scalar: int,
	// pending is the number of continuation bytes still needed to
	// complete the open multi-byte scalar (0 = none).
	pending: u8,
	// breaks is the number of line breaks resolved strictly before
	// the current byte (the provisional trailing CR excluded).
	breaks: int,
	// prev_cr: the previous byte was a '\r' whose break-ness is
	// unresolved (depends on the current byte).
	prev_cr: bool,
}

// cursor_from derives a cursor positioned at the start of a run whose
// metrics are `carry` (the fold of everything before the run).
cursor_from :: proc(carry: Metrics) -> Coord_Cursor {
	c := Coord_Cursor{}
	c.scalar = carry.scalar_count - (1 if carry.boundary.tail_expects > 0 else 0)
	c.pending = carry.boundary.tail_expects
	c.breaks = line_break_count(carry) - (1 if carry.boundary.ends_with_cr else 0)
	c.prev_cr = carry.boundary.ends_with_cr
	return c
}

// lead_len returns the number of continuation bytes a scalar lead byte
// expects, or 0 when `b` is not a lead byte (the counting model of
// `metrics_of`).
lead_len :: proc(b: u8) -> u8 {
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

// advance_scalar processes one byte of the scalar state machine.
advance_scalar :: proc(c: ^Coord_Cursor, b: u8) {
	if c.pending > 0 {
		if is_continuation(b) {
			c.pending -= 1
			if c.pending == 0 {
				c.scalar += 1
			}
		} else {
			// The open scalar broke: it completes (invalid), and b
			// starts a new scalar.
			c.scalar += 1
			c.pending = 0
			if n := lead_len(b); n > 0 {
				c.pending = n
			} else {
				c.scalar += 1
			}
		}
	} else {
		if n := lead_len(b); n > 0 {
			c.pending = n
		} else {
			c.scalar += 1
		}
	}
}

// advance_breaks processes one byte of the line-break state machine
// (resolving the provisional CR carry). Returns the byte offset of the
// line start when a break completes; `-1` when no break completed.
advance_breaks :: proc(c: ^Coord_Cursor, b: u8, q: int) -> int {
	if b == '\r' {
		if c.prev_cr {
			c.breaks += 1 // the previous CR was a lone break
			c.prev_cr = true
			return q // line starts at q (after the CR at q-1/boundary)
		}
		c.prev_cr = true
		return -1
	}
	if b == '\n' {
		c.breaks += 1 // LF (or CRLF) is one break
		c.prev_cr = false
		return q + 1
	}
	if c.prev_cr {
		c.breaks += 1 // the previous CR was a lone break
		c.prev_cr = false
		return q
	}
	c.prev_cr = false
	return -1
}

// descend_byte descends to the piece containing byte offset `byte_pos`
// (0 <= byte_pos < total), folding skipped subtrees and pieces into
// `carry` and accumulating their byte count in `base`. Returns the
// piece, its chunk data, and the offset within the piece.
descend_byte :: proc(
	tree: ^Tree,
	byte_pos: int,
	carry: ^Metrics,
	base: ^int,
) -> (piece: Piece, data: []byte, off: int) {
	n := tree.root
	p := byte_pos
	for n.kind == .Internal {
		idx := 0
		for idx < n.child_count - 1 && p >= n.children[idx].metrics.byte_count {
			carry^ = combine(carry^, n.children[idx].metrics)
			base^ += n.children[idx].metrics.byte_count
			p -= n.children[idx].metrics.byte_count
			idx += 1
		}
		n = n.children[idx]
	}
	i := 0
	for i < n.piece_count - 1 && p >= n.pieces[i].byte_length {
		cd := chunk.data(tree.store, n.pieces[i].store_id)
		pm := metrics_of(cd[n.pieces[i].byte_start:n.pieces[i].byte_start + n.pieces[i].byte_length])
		carry^ = combine(carry^, pm)
		base^ += n.pieces[i].byte_length
		p -= n.pieces[i].byte_length
		i += 1
	}
	piece = n.pieces[i]
	data = chunk.data(tree.store, piece.store_id)
	return piece, data, p
}

// descend_scalar descends to the piece where the scalar with index
// `target` (target < combine(root).scalar_count) starts, folding
// skipped content into `carry`/`base`. The invariant
// target >= carry.scalar_count holds throughout (a scalar whose start
// is in already-folded content is never sought here).
descend_scalar :: proc(
	tree: ^Tree,
	target: int,
	carry: ^Metrics,
	base: ^int,
) -> (piece: Piece, data: []byte) {
	n := tree.root
	for n.kind == .Internal {
		idx := 0
		for idx < n.child_count {
			c2 := combine(carry^, n.children[idx].metrics)
			if target < c2.scalar_count {
				break
			}
			carry^ = c2
			base^ += n.children[idx].metrics.byte_count
			idx += 1
		}
		assert(idx < n.child_count, "rope: scalar target must fall inside a child")
		n = n.children[idx]
	}
	i := 0
	for i < n.piece_count {
		cd := chunk.data(tree.store, n.pieces[i].store_id)
		pm := metrics_of(cd[n.pieces[i].byte_start:n.pieces[i].byte_start + n.pieces[i].byte_length])
		c2 := combine(carry^, pm)
		if target < c2.scalar_count {
			break
		}
		carry^ = c2
		base^ += n.pieces[i].byte_length
		i += 1
	}
	assert(i < n.piece_count, "rope: scalar target must fall inside a piece")
	return n.pieces[i], chunk.data(tree.store, n.pieces[i].store_id)
}

// descend_breaks descends to the piece where the break with index
// `target` resolves (target < resolved(root)), folding skipped content
// into `carry`/`base`. A break that resolves exactly at a boundary
// (a provisional CR) resolves in the following piece's decode.
descend_breaks :: proc(
	tree: ^Tree,
	target: int,
	carry: ^Metrics,
	base: ^int,
) -> (piece: Piece, data: []byte) {
	resolved := proc(m: Metrics) -> int {
		return line_break_count(m) - (1 if m.boundary.ends_with_cr else 0)
	}
	n := tree.root
	for n.kind == .Internal {
		idx := 0
		for idx < n.child_count {
			c2 := combine(carry^, n.children[idx].metrics)
			if target < resolved(c2) {
				break
			}
			carry^ = c2
			base^ += n.children[idx].metrics.byte_count
			idx += 1
		}
		assert(idx < n.child_count, "rope: break target must fall inside a child")
		n = n.children[idx]
	}
	i := 0
	for i < n.piece_count {
		cd := chunk.data(tree.store, n.pieces[i].store_id)
		pm := metrics_of(cd[n.pieces[i].byte_start:n.pieces[i].byte_start + n.pieces[i].byte_length])
		c2 := combine(carry^, pm)
		if target < resolved(c2) {
			break
		}
		carry^ = c2
		base^ += n.pieces[i].byte_length
		i += 1
	}
	assert(i < n.piece_count, "rope: break target must fall inside a piece")
	return n.pieces[i], chunk.data(tree.store, n.pieces[i].store_id)
}

// decode_scalar_start decodes `data` (a piece slice) forward from the
// cursor state and returns the offset within `data` where the scalar
// with index `target` starts. Precondition: target >= cursor.scalar
// and target < combine(cursor metrics, metrics_of(data)).scalar_count.
decode_scalar_start :: proc(c: ^Coord_Cursor, data: []byte, target: int) -> int {
	for q := 0; q < len(data); q += 1 {
		b := data[q]
		if c.pending > 0 {
			if is_continuation(b) {
				c.pending -= 1
				if c.pending == 0 {
					c.scalar += 1
				}
			} else {
				c.scalar += 1
				c.pending = 0
				if c.scalar == target {
					return q
				}
				if n := lead_len(b); n > 0 {
					c.pending = n
				} else {
					c.scalar += 1
				}
			}
		} else {
			if c.scalar == target {
				return q
			}
			if n := lead_len(b); n > 0 {
				c.pending = n
			} else {
				c.scalar += 1
			}
		}
	}
	assert(false, "rope: target scalar must start within the piece")
	return 0
}

// decode_scalar_at returns the index of the scalar containing byte
// offset `q` within `data` (a piece slice), continuing from the cursor
// state. Precondition: 0 <= q < len(data).
decode_scalar_at :: proc(c: ^Coord_Cursor, data: []byte, q: int) -> int {
	for i := 0; i < q; i += 1 {
		advance_scalar(c, data[i])
	}
	b := data[q]
	if c.pending > 0 && !is_continuation(b) {
		// The open scalar breaks at q: q starts a new scalar.
		c.scalar += 1
	}
	return c.scalar
}

// decode_break_position decodes `data` (a piece slice) forward from
// the cursor state until the `need`-th additional break resolves, and
// returns the offset within `data` of the line start just past it.
// Precondition: need >= 1 and the break resolves within the piece.
decode_break_position :: proc(c: ^Coord_Cursor, data: []byte, need: int) -> int {
	remaining := need
	for q := 0; q < len(data); q += 1 {
		pos := advance_breaks(c, data[q], q)
		if pos >= 0 {
			remaining -= 1
			if remaining == 0 {
				return pos
			}
		}
	}
	assert(false, "rope: target break must resolve within the piece")
	return 0
}

// tree_scalar_count returns the number of Unicode scalars.
tree_scalar_count :: proc(tree: ^Tree) -> int {
	if tree.root == nil {
		return 0
	}
	return tree.root.metrics.scalar_count
}

// tree_line_count returns line_break_count + 1 (an empty tree has one
// empty line).
tree_line_count :: proc(tree: ^Tree) -> int {
	if tree.root == nil {
		return 1
	}
	return line_break_count(tree.root.metrics) + 1
}

// tree_byte_to_scalar maps a byte offset (0..=total) to the index of
// the scalar containing it (or scalar_count at the end).
tree_byte_to_scalar :: proc(
	tree: ^Tree,
	byte_pos: int,
	allocator := context.allocator,
) -> (Scalar_Index, errs.Error) {
	total := tree_byte_count(tree)
	if byte_pos < 0 || byte_pos > total {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: byte offset %v outside [0, %v]",
			byte_pos,
			total,
			allocator = allocator,
		)
	}
	if byte_pos == total {
		return Scalar_Index(tree_scalar_count(tree)), {}
	}
	carry := Metrics{}
	base := 0
	piece, data, off := descend_byte(tree, byte_pos, &carry, &base)
	slice := data[piece.byte_start:piece.byte_start + piece.byte_length]
	c := cursor_from(carry)
	return Scalar_Index(decode_scalar_at(&c, slice, off)), {}
}

// tree_scalar_to_byte maps a scalar index (0..=scalar_count) to the
// byte offset of its first byte (total at scalar_count).
tree_scalar_to_byte :: proc(
	tree: ^Tree,
	scalar: Scalar_Index,
	allocator := context.allocator,
) -> (int, errs.Error) {
	total := tree_scalar_count(tree)
	if scalar < 0 || scalar > Scalar_Index(total) {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: scalar index %v outside [0, %v]",
			scalar,
			total,
			allocator = allocator,
		)
	}
	if tree.root == nil {
		return 0, {}
	}
	if scalar == Scalar_Index(total) {
		return tree_byte_count(tree), {}
	}
	carry := Metrics{}
	base := 0
	piece, data := descend_scalar(tree, int(scalar), &carry, &base)
	slice := data[piece.byte_start:piece.byte_start + piece.byte_length]
	c := cursor_from(carry)
	off := decode_scalar_start(&c, slice, int(scalar))
	// base is already this piece's document offset; off is relative
	// to the piece slice (piece.byte_start is chunk-relative and must
	// not be added).
	return base + off, {}
}

// tree_byte_to_line maps a byte offset to its line index (the last
// line at the end of the text).
tree_byte_to_line :: proc(
	tree: ^Tree,
	byte_pos: int,
	allocator := context.allocator,
) -> (Line_Index, errs.Error) {
	total := tree_byte_count(tree)
	if byte_pos < 0 || byte_pos > total {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: byte offset %v outside [0, %v]",
			byte_pos,
			total,
			allocator = allocator,
		)
	}
	if byte_pos == total {
		if tree.root == nil {
			return 0, {}
		}
		return Line_Index(line_break_count(tree.root.metrics)), {}
	}
	carry := Metrics{}
	base := 0
	piece, data, off := descend_byte(tree, byte_pos, &carry, &base)
	slice := data[piece.byte_start:piece.byte_start + piece.byte_length]
	c := cursor_from(carry)
	for i := 0; i < off; i += 1 {
		advance_breaks(&c, slice[i], i)
	}
	// Resolve a provisional CR at off-1 against the byte at off.
	line := c.breaks
	if c.prev_cr && slice[off] != '\n' {
		line += 1
	}
	return Line_Index(line), {}
}

// tree_line_start returns the byte offset of the first byte of line
// `line` (0..=line_break_count): byte 0 for line 0, one past the
// line's preceding break otherwise.
tree_line_start :: proc(
	tree: ^Tree,
	line: Line_Index,
	allocator := context.allocator,
) -> (int, errs.Error) {
	breaks := 0
	if tree.root != nil {
		breaks = line_break_count(tree.root.metrics)
	}
	if line < 0 || line > Line_Index(breaks) {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: line %v outside [0, %v]",
			line,
			breaks,
			allocator = allocator,
		)
	}
	if line == 0 {
		return 0, {}
	}
	target := int(line) - 1
	// The final break may be the tree's trailing CR: its line starts
	// at the end of the text.
	if target == breaks - 1 && tree.root.metrics.boundary.ends_with_cr {
		return tree_byte_count(tree), {}
	}
	carry := Metrics{}
	base := 0
	piece, data := descend_breaks(tree, target, &carry, &base)
	slice := data[piece.byte_start:piece.byte_start + piece.byte_length]
	c := cursor_from(carry)
	need := target + 1 - c.breaks
	pos := decode_break_position(&c, slice, need)
	// base is already this piece's document offset (see
	// tree_scalar_to_byte).
	return base + pos, {}
}

// tree_line_end returns the byte offset just past the line's break
// (== tree_line_start(line+1); the text end for the last line).
tree_line_end :: proc(
	tree: ^Tree,
	line: Line_Index,
	allocator := context.allocator,
) -> (int, errs.Error) {
	breaks := 0
	if tree.root != nil {
		breaks = line_break_count(tree.root.metrics)
	}
	if line < 0 || line > Line_Index(breaks) {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: line %v outside [0, %v]",
			line,
			breaks,
			allocator = allocator,
		)
	}
	if line == Line_Index(breaks) {
		return tree_byte_count(tree), {}
	}
	return tree_line_start(tree, line + 1, allocator)
}

// tree_byte_to_line_col maps a byte offset to its line and scalar
// column (0-based) within that line.
tree_byte_to_line_col :: proc(
	tree: ^Tree,
	byte_pos: int,
	allocator := context.allocator,
) -> (Line_Index, Column_Index, errs.Error) {
	line, lerr := tree_byte_to_line(tree, byte_pos, allocator)
	if !errs.ok(lerr) {
		return 0, 0, lerr
	}
	start, serr := tree_line_start(tree, line, allocator)
	if !errs.ok(serr) {
		return 0, 0, serr
	}
	pos_scalar, perr := tree_byte_to_scalar(tree, byte_pos, allocator)
	if !errs.ok(perr) {
		return 0, 0, perr
	}
	start_scalar, perr2 := tree_byte_to_scalar(tree, start, allocator)
	if !errs.ok(perr2) {
		return 0, 0, perr2
	}
	return line, Column_Index(pos_scalar - start_scalar), {}
}

// tree_line_col_to_byte maps a line and scalar column to the byte
// offset of that column's scalar (the line end when the column is the
// line's scalar length).
tree_line_col_to_byte :: proc(
	tree: ^Tree,
	line: Line_Index,
	col: Column_Index,
	allocator := context.allocator,
) -> (int, errs.Error) {
	start, serr := tree_line_start(tree, line, allocator)
	if !errs.ok(serr) {
		return 0, serr
	}
	end, eerr := tree_line_end(tree, line, allocator)
	if !errs.ok(eerr) {
		return 0, eerr
	}
	start_scalar, perr := tree_byte_to_scalar(tree, start, allocator)
	if !errs.ok(perr) {
		return 0, perr
	}
	end_scalar, perr2 := tree_byte_to_scalar(tree, end, allocator)
	if !errs.ok(perr2) {
		return 0, perr2
	}
	length := int(end_scalar - start_scalar)
	if col < 0 || col > Column_Index(length) {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: column %v outside [0, %v] for line %v",
			col,
			length,
			line,
			allocator = allocator,
		)
	}
	if col == Column_Index(length) {
		return end, {}
	}
	return tree_scalar_to_byte(tree, start_scalar + Scalar_Index(col), allocator)
}

// tree_scalar_to_line_col maps a scalar index to its line and scalar
// column.
tree_scalar_to_line_col :: proc(
	tree: ^Tree,
	scalar: Scalar_Index,
	allocator := context.allocator,
) -> (Line_Index, Column_Index, errs.Error) {
	byte_pos, berr := tree_scalar_to_byte(tree, scalar, allocator)
	if !errs.ok(berr) {
		return 0, 0, berr
	}
	return tree_byte_to_line_col(tree, byte_pos, allocator)
}

// tree_line_col_to_scalar maps a line and scalar column to the scalar
// index of that column (the line end scalar for a column equal to the
// line's scalar length).
tree_line_col_to_scalar :: proc(
	tree: ^Tree,
	line: Line_Index,
	col: Column_Index,
	allocator := context.allocator,
) -> (Scalar_Index, errs.Error) {
	start, serr := tree_line_start(tree, line, allocator)
	if !errs.ok(serr) {
		return 0, serr
	}
	end, eerr := tree_line_end(tree, line, allocator)
	if !errs.ok(eerr) {
		return 0, eerr
	}
	start_scalar, perr := tree_byte_to_scalar(tree, start, allocator)
	if !errs.ok(perr) {
		return 0, perr
	}
	end_scalar, perr2 := tree_byte_to_scalar(tree, end, allocator)
	if !errs.ok(perr2) {
		return 0, perr2
	}
	length := int(end_scalar - start_scalar)
	if col < 0 || col > Column_Index(length) {
		return 0, errs.newf(
			.Invalid_Input,
			"rope: column %v outside [0, %v] for line %v",
			col,
			length,
			line,
			allocator = allocator,
		)
	}
	return start_scalar + Scalar_Index(col), {}
}
