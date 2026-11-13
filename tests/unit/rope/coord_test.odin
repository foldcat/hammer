// Tests for rope coordinate conversion (M02.04): byte <-> scalar,
// byte <-> line/column, line start/end, against hand-computed cases,
// round-trip properties, an independent oracle model, and a randomized
// differential over tree mutations.
package rope_test

import "core:bytes"
import "core:fmt"
import "core:testing"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import rope "hammer:core/rope"

// Coord_Model is the independent reference: per-position scalar and
// line mappings plus per-scalar and per-line positions, built by a
// separate implementation of the counting policy (not the rope code).
Coord_Model :: struct {
	scalar_of_byte: []int, // len n+1
	scalar_start:   []int, // len scalar_count + 1 (last = n)
	line_of_byte:   []int, // len n+1
	line_start:     []int, // len line_count
	line_end:       []int, // len line_count
	col_of_byte:    []int, // len n+1
}

// model_destroy frees the model's arrays.
model_destroy :: proc(m: ^Coord_Model) {
	delete(m.scalar_of_byte)
	delete(m.scalar_start)
	delete(m.line_of_byte)
	delete(m.line_start)
	delete(m.line_end)
	delete(m.col_of_byte)
}

// model_lead returns the continuation count a lead byte needs (the
// oracle's own copy of the counting rule).
model_lead :: proc(b: u8) -> int {
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

// build_model computes the reference model for `data` with an
// implementation independent of the rope's (linear forward passes).
build_model :: proc(data: []byte) -> Coord_Model {
	n := len(data)
	m := Coord_Model {
		scalar_of_byte = make([]int, n + 1),
		line_of_byte   = make([]int, n + 1),
		col_of_byte    = make([]int, n + 1),
	}

	// Scalar pass: record the containing scalar of every byte.
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
				// The pending scalar broke: b starts a new scalar.
				m.scalar_of_byte[i] = scalar + 1
				scalar += 1
				pending = 0
				if l := model_lead(b); l > 0 {
					pending = l
				} else {
					scalar += 1
				}
			}
		} else {
			m.scalar_of_byte[i] = scalar
			if l := model_lead(b); l > 0 {
				pending = l
			} else {
				scalar += 1
			}
		}
	}
	scalar_count := scalar + (1 if pending > 0 else 0)
	m.scalar_of_byte[n] = scalar_count

	// Scalar start offsets.
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

	// Line pass: record the containing line of every byte.
	line := 0
	prev_cr := false
	for i := 0; i < n; i += 1 {
		b := data[i]
		if prev_cr && b != '\n' {
			// The CR before this byte was a lone break: this byte is
			// on the next line.
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

	// Line start/end offsets.
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

	// Columns.
	for i := 0; i <= n; i += 1 {
		l := m.line_of_byte[i]
		m.col_of_byte[i] = m.scalar_of_byte[i] - m.scalar_of_byte[m.line_start[l]]
	}
	return m
}

// expect_model_equal checks every conversion of the tree against the
// reference model.
expect_model_equal :: proc(t: ^testing.T, tree: ^rope.Tree, m: ^Coord_Model, what: string) {
	n := rope.tree_byte_count(tree)
	testing.expect(t, n == len(m.scalar_of_byte) - 1)
	testing.expect(t, rope.tree_scalar_count(tree) == len(m.scalar_start) - 1)
	testing.expect(t, rope.tree_line_count(tree) == len(m.line_start))

	for b := 0; b <= n; b += 1 {
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

	for s := 0; s < len(m.scalar_start); s += 1 {
		bp, berr := rope.tree_scalar_to_byte(tree, rope.Scalar_Index(s))
		testing.expectf(t, errs.ok(berr) && bp == m.scalar_start[s], "%s: scalar_to_byte(%v): got %v want %v", what, s, bp, m.scalar_start[s])
	}

	for l := 0; l < len(m.line_start); l += 1 {
		start, serr := rope.tree_line_start(tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(serr) && start == m.line_start[l], "%s: line_start(%v): got %v want %v", what, l, start, m.line_start[l])
		e_pos, eerr := rope.tree_line_end(tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(eerr) && e_pos == m.line_end[l], "%s: line_end(%v): got %v want %v", what, l, e_pos, m.line_end[l])
	}
}

// test_coord_hand_cases pins hand-computed conversions on a fixed text
// with multi-byte scalars, CRLF, and a lone CR.
@(test)
test_coord_hand_cases :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 3})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	// T = "aé\nb\r\nc\rd": 10 bytes, 9 scalars, 3 breaks, 4 lines.
	tree_append_text(t, &tree, "aé\nb\r\nc\rd")

	// byte -> scalar: interior bytes map to the containing scalar.
	scalar_wants := []int{0, 1, 1, 2, 3, 4, 5, 6, 7, 8}
	for want, b in scalar_wants {
		s, err := rope.tree_byte_to_scalar(&tree, b)
		testing.expectf(t, errs.ok(err) && int(s) == want, "byte_to_scalar(%v): got %v want %v", b, s, want)
	}
	s, err := rope.tree_byte_to_scalar(&tree, 10)
	testing.expect(t, errs.ok(err) && s == 9)

	// scalar -> byte.
	byte_wants := []int{0, 1, 3, 4, 5, 6, 7, 8, 9}
	for want, s2 in byte_wants {
		bp, serr := rope.tree_scalar_to_byte(&tree, rope.Scalar_Index(s2))
		testing.expectf(t, errs.ok(serr) && bp == want, "scalar_to_byte(%v): got %v want %v", s2, bp, want)
	}
	bp, berr := rope.tree_scalar_to_byte(&tree, 9)
	testing.expect(t, errs.ok(berr) && bp == 10)

	// byte -> line.
	line_wants := []int{0, 0, 0, 0, 1, 1, 1, 2, 2, 3}
	for want, b in line_wants {
		l, lerr := rope.tree_byte_to_line(&tree, b)
		testing.expectf(t, errs.ok(lerr) && int(l) == want, "byte_to_line(%v): got %v want %v", b, l, want)
	}
	l_end, lerr2 := rope.tree_byte_to_line(&tree, 10)
	testing.expect(t, errs.ok(lerr2) && l_end == 3)

	// line start/end.
	start_wants := []int{0, 4, 7, 9}
	for want, l in start_wants {
		start, serr := rope.tree_line_start(&tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(serr) && start == want, "line_start(%v): got %v want %v", l, start, want)
	}
	e_pos_wants := []int{4, 7, 9, 10}
	for want, l in e_pos_wants {
		e_pos, lerr := rope.tree_line_end(&tree, rope.Line_Index(l))
		testing.expectf(t, errs.ok(lerr) && e_pos == want, "line_end(%v): got %v want %v", l, e_pos, want)
	}

	// line/column: the '\r' of the CRLF is column 1 of line 1.
	line, col, cerr := rope.tree_byte_to_line_col(&tree, 5)
	testing.expect(t, errs.ok(cerr) && line == 1 && col == 1)
	bp2, berr2 := rope.tree_line_col_to_byte(&tree, 1, 1)
	testing.expect(t, errs.ok(berr2) && bp2 == 5)
	// Column == line scalar length maps to the line end.
	bp3, berr3 := rope.tree_line_col_to_byte(&tree, 0, 3)
	testing.expect(t, errs.ok(berr3) && bp3 == 4)
}

// test_coord_empty_tree pins the empty-tree edges: one empty line,
// zero scalars.
@(test)
test_coord_empty_tree :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 8})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	testing.expect(t, rope.tree_scalar_count(&tree) == 0)
	testing.expect(t, rope.tree_line_count(&tree) == 1)

	s, err := rope.tree_byte_to_scalar(&tree, 0)
	testing.expect(t, errs.ok(err) && s == 0)
	l, err2 := rope.tree_byte_to_line(&tree, 0)
	testing.expect(t, errs.ok(err2) && l == 0)
	bp, err3 := rope.tree_scalar_to_byte(&tree, 0)
	testing.expect(t, errs.ok(err3) && bp == 0)
	start, err4 := rope.tree_line_start(&tree, 0)
	testing.expect(t, errs.ok(err4) && start == 0)
	e_pos, err5 := rope.tree_line_end(&tree, 0)
	testing.expect(t, errs.ok(err5) && e_pos == 0)
}

// test_coord_errors pins the bounds validation of every conversion.
@(test)
test_coord_errors :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 4})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	tree_append_text(t, &tree, "hello\nworld")

	expect_invalid := proc(t: ^testing.T, err: errs.Error, what: string) {
		testing.expectf(t, err.kind == .Invalid_Input, "%s: got %v", what, err.kind)
		e := err
		errs.destroy(&e)
	}

	_, err := rope.tree_byte_to_scalar(&tree, -1)
	expect_invalid(t, err, "byte_to_scalar(-1)")
	_, err = rope.tree_byte_to_scalar(&tree, 12)
	expect_invalid(t, err, "byte_to_scalar(12)")
	_, err = rope.tree_scalar_to_byte(&tree, -1)
	expect_invalid(t, err, "scalar_to_byte(-1)")
	_, err = rope.tree_scalar_to_byte(&tree, 100)
	expect_invalid(t, err, "scalar_to_byte(100)")
	_, err = rope.tree_byte_to_line(&tree, 99)
	expect_invalid(t, err, "byte_to_line(99)")
	_, err = rope.tree_line_start(&tree, 5)
	expect_invalid(t, err, "line_start(5)")
	_, err = rope.tree_line_end(&tree, -2)
	expect_invalid(t, err, "line_end(-2)")
	_, err = rope.tree_line_col_to_byte(&tree, 0, 99)
	expect_invalid(t, err, "line_col_to_byte col 99")
	_, err = rope.tree_line_col_to_byte(&tree, 9, 0)
	expect_invalid(t, err, "line_col_to_byte line 9")
	_, _, err = rope.tree_byte_to_line_col(&tree, 77)
	expect_invalid(t, err, "byte_to_line_col(77)")
}

// test_coord_roundtrips checks the round-trip properties on a fixed
// tricky text.
@(test)
test_coord_roundtrips :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 2})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {})))
	defer rope.tree_destroy(&tree)

	text := "xé\r€\n\r\n中😀\ry"
	tree_append_text(t, &tree, text)
	data := bytes_of(text)
	model := build_model(data)
	defer model_destroy(&model)

	for b := 0; b <= len(data); b += 1 {
		s, serr := rope.tree_byte_to_scalar(&tree, b)
		testing.expect(t, errs.ok(serr))
		bp, berr := rope.tree_scalar_to_byte(&tree, s)
		testing.expect(t, errs.ok(berr))
		testing.expectf(t, bp == model.scalar_start[int(s)], "scalar_to_byte(byte_to_scalar(%v)) must be the scalar start", b)

		l, lerr := rope.tree_byte_to_line(&tree, b)
		testing.expect(t, errs.ok(lerr))
		_, col, cerr := rope.tree_byte_to_line_col(&tree, b)
		testing.expect(t, errs.ok(cerr))
		bp2, b2err := rope.tree_line_col_to_byte(&tree, l, col)
		testing.expect(t, errs.ok(b2err))
		testing.expectf(t, bp2 == model.scalar_start[int(s)], "line_col_to_byte(byte_to_line_col(%v)) must be the scalar start", b)
	}

	for s := 0; s <= len(model.scalar_start) - 1; s += 1 {
		bp, berr := rope.tree_scalar_to_byte(&tree, rope.Scalar_Index(s))
		testing.expect(t, errs.ok(berr))
		s2, serr := rope.tree_byte_to_scalar(&tree, bp)
		testing.expectf(t, errs.ok(serr) && int(s2) == s, "byte_to_scalar(scalar_to_byte(%v)) must round-trip", s)
	}
}

// test_coord_randomized_differential mutates the tree randomly and
// compares every conversion against the independent model every 10
// steps.
@(test)
test_coord_randomized_differential :: proc(t: ^testing.T) {
	store: chunk.Store
	chunk.init(&store, {chunk_size = 5})
	defer chunk.destroy(&store)

	tree: rope.Tree
	testing.expect(t, errs.ok(rope.tree_init(&tree, &store, {target_leaf_bytes = 24})))
	defer rope.tree_destroy(&tree)

	alphabet := bytes_of("ab\r\né€😀z中✓")
	ref := make([dynamic]u8, context.allocator)
	defer delete(ref)

	state: u64 = 0x9e37_79b9_7f4a_7c15
	next := proc(x: ^u64) -> u64 {
		v := x^
		v ~= v << 13
		v ~= v >> 7
		v ~= v << 17
		x^ = v
		return v
	}

	for step in 0 ..< 400 {
		op := next(&state) % 3
		if op == 0 || op == 1 {
			piece := make([]u8, int(next(&state) % 30), context.allocator)
			for &b in piece {
				b = alphabet[int(next(&state) % u64(len(alphabet)))]
			}
			pos := len(ref)
			if op == 0 {
				pos = int(next(&state) % u64(len(ref) + 1))
			}
			err := rope.tree_insert(&tree, pos, piece)
			testing.expect(t, errs.ok(err))
			if len(piece) > 0 {
				ok, _ := inject_at_elems(&ref, pos, ..piece)
				testing.expect(t, ok)
			}
			delete(piece, context.allocator)
		} else {
			if len(ref) == 0 {
				continue
			}
			lo := int(next(&state) % u64(len(ref)))
			hi := lo + int(next(&state) % u64(len(ref) - lo + 1))
			err := rope.tree_delete(&tree, rope.Byte_Range{lo, hi})
			testing.expect(t, errs.ok(err))
			if hi > lo {
				remove_range(&ref, lo, hi)
			}
		}

		if step % 10 == 0 {
			got := tree_flatten(t, &tree)
			testing.expectf(t, bytes.equal(got, ref[:]), "content at step %v", step)
			delete(got)
			expect_tree_ok(t, &tree, fmt.tprintf("step %v", step))

			model := build_model(ref[:])
			expect_model_equal(t, &tree, &model, fmt.tprintf("step %v", step))
			model_destroy(&model)
		}
	}

	// Final full comparison.
	model := build_model(ref[:])
	defer model_destroy(&model)
	expect_model_equal(t, &tree, &model, "final")
}
