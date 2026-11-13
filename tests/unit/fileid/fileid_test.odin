// Tests for canonical file identity (M03.01): `hammer:core/fileid` —
// platform File_ID construction and mapping, equality/total order,
// stamp validation, the external-change status policy, and randomized
// differentials against independent reference implementations (the
// established M02 discipline: the reference must be a second, different
// implementation of the same policy, so a policy bug shared by both
// sides cannot hide).
package fileid_test

import "core:testing"

import errs "hammer:core/errs"
import fileid "hammer:core/fileid"

@(test)
test_unix_id_mapping :: proc(t: ^testing.T) {
	id := fileid.unix_id(2050, 42)
	testing.expect(t, id.kind == .Unix)
	testing.expect(t, id.hi == 2050)
	testing.expect(t, id.lo == 42)
	testing.expect(t, !fileid.is_none(id))

	// POSIX: inode 0 is never a valid file -> not identifiable.
	none := fileid.unix_id(2050, 0)
	testing.expect(t, fileid.is_none(none))
	testing.expect(t, fileid.id_equal(none, fileid.FILE_ID_NONE))

	// A zero device with a nonzero inode is structurally valid input
	// (anonymous devices) and is kept as-is, never asserted on.
	zero_dev := fileid.unix_id(0, 7)
	testing.expect(t, !fileid.is_none(zero_dev))
	testing.expect(t, zero_dev.hi == 0 && zero_dev.lo == 7)
}

@(test)
test_windows_id_mapping :: proc(t: ^testing.T) {
	id := fileid.windows_id(0xDEAD_BEEF, 0x0102_0304_0506_0708)
	testing.expect(t, id.kind == .Windows)
	testing.expect(t, id.hi == 0xDEAD_BEEF) // zero-extended from u32
	testing.expect(t, id.lo == 0x0102_0304_0506_0708)

	// A file index of 0 means the volume provides no stable identity.
	none := fileid.windows_id(0xDEAD_BEEF, 0)
	testing.expect(t, fileid.is_none(none))

	// Volume serial 0 alone occurs on real volumes and is not invalid.
	zero_vol := fileid.windows_id(0, 9)
	testing.expect(t, !fileid.is_none(zero_vol))
	testing.expect(t, zero_vol.hi == 0 && zero_vol.lo == 9)
}

@(test)
test_id_equality_and_order :: proc(t: ^testing.T) {
	u_a := fileid.unix_id(1, 2)
	u_a2 := fileid.unix_id(1, 2)
	u_b := fileid.unix_id(1, 3)
	u_c := fileid.unix_id(2, 1)
	w_a := fileid.windows_id(1, 2)

	// Equality: reflexive, symmetric, cross-kind never equal.
	testing.expect(t, fileid.id_equal(u_a, u_a2))
	testing.expect(t, fileid.id_equal(u_a2, u_a))
	testing.expect(t, !fileid.id_equal(u_a, u_b))
	testing.expect(t, !fileid.id_equal(u_a, u_c))
	testing.expect(t, !fileid.id_equal(u_a, w_a))
	testing.expect(t, fileid.id_cmp(u_a, u_a2) == 0)

	// None is a single canonical value: hi/lo are ignored by every
	// comparison, so two "none" values can never compare unequal.
	none := fileid.FILE_ID_NONE
	garbage_none := fileid.File_ID{kind = .None, hi = 99, lo = 88}
	testing.expect(t, fileid.is_none(garbage_none))
	testing.expect(t, fileid.id_equal(none, garbage_none))
	testing.expect(t, fileid.id_cmp(none, garbage_none) == 0)
	testing.expect(t, !fileid.id_equal(none, u_a))
	testing.expect(t, fileid.id_cmp(none, u_a) < 0)
	testing.expect(t, fileid.id_cmp(u_a, none) > 0)

	// Total order spot checks: kind-major, then hi, then lo.
	testing.expect(t, fileid.id_cmp(u_a, u_b) < 0) // same dev, ino 2 < 3
	testing.expect(t, fileid.id_cmp(u_b, u_c) < 0) // dev 1 < dev 2
	testing.expect(t, fileid.id_cmp(u_c, w_a) < 0) // Unix < Windows
	testing.expect(t, fileid.id_cmp(u_c, u_b) > 0)

	// Antisymmetry and cmp==0 iff equal, over every ordered pair.
	ids := [?]fileid.File_ID{none, u_a, u_b, u_c, w_a}
	for i in 0 ..< len(ids) {
		for j in 0 ..< len(ids) {
			fwd := fileid.id_cmp(ids[i], ids[j])
			bwd := fileid.id_cmp(ids[j], ids[i])
			testing.expectf(t, fwd == -bwd, "antisymmetry failed at (%d, %d)", i, j)
			testing.expectf(
				t,
				(fwd == 0) == fileid.id_equal(ids[i], ids[j]),
				"cmp/equal agreement failed at (%d, %d)",
				i,
				j,
			)
		}
	}
}

@(test)
test_make_stamp_validation :: proc(t: ^testing.T) {
	id := fileid.unix_id(5, 9)

	// Boundary nsec values are valid; any size and mtime (including
	// negative — pre-1970, valid on FAT) passes through.
	low, low_err := fileid.make_stamp(id, 1234, -86_400, 0)
	testing.expect(t, errs.ok(low_err))
	testing.expect(t, low.size == 1234 && low.mtime_sec == -86_400 && low.mtime_nsec == 0)

	high, high_err := fileid.make_stamp(id, 0, 0, 999_999_999)
	testing.expect(t, errs.ok(high_err))
	testing.expect(t, high.mtime_nsec == 999_999_999)

	// nsec >= 1e9 is out of range: .Invalid_Input, never an assertion.
	_, bad_err := fileid.make_stamp(id, 0, 0, 1_000_000_000)
	testing.expect(t, bad_err.kind == .Invalid_Input)
	desc := errs.describe(bad_err, context.allocator)
	defer delete(desc, context.allocator)
	testing.expect(t, len(desc) > 0)
	errs.destroy(&bad_err)

	_, bad2_err := fileid.make_stamp(id, 0, 0, 4_000_000_000)
	testing.expect(t, bad2_err.kind == .Invalid_Input)
	errs.destroy(&bad2_err)
}

@(test)
test_stamp_status_table :: proc(t: ^testing.T) {
	id_a := fileid.unix_id(10, 20)
	base := fileid.File_Stamp{id = id_a, size = 100, mtime_sec = 1000, mtime_nsec = 500}

	// Identical stamps: unchanged.
	same := base
	testing.expect(t, fileid.stamp_status(base, same) == .Unchanged)

	// Same identity, one version field differs: changed.
	changed_cases := []fileid.File_Stamp {
		{id_a, 101, 1000, 500},
		{id_a, 100, 1001, 500},
		{id_a, 100, 1000, 501},
		{id_a, 0, 0, 0},
	}
	for changed in changed_cases {
		testing.expect(t, fileid.stamp_status(base, changed) == .Changed)
		testing.expect(t, fileid.stamp_status(changed, base) == .Changed)
	}

	// Different identity: replaced, in every way identity can differ —
	// and symmetric, regardless of version.
	replaced_cases := []fileid.File_Stamp {
		{id = fileid.unix_id(10, 21)}, // different inode
		{id = fileid.unix_id(11, 20)}, // different device
		{id = fileid.windows_id(10, 20)}, // cross-kind, same hi/lo
	}
	for replaced in replaced_cases {
		testing.expect(t, fileid.stamp_status(base, replaced) == .Replaced)
		testing.expect(t, fileid.stamp_status(replaced, base) == .Replaced)
	}

	// None on either side: identity unverifiable -> version-only, and
	// never .Replaced (best-effort policy, documented on the package).
	none_stamp := fileid.File_Stamp {
		id = fileid.FILE_ID_NONE,
		size = 100,
		mtime_sec = 1000,
		mtime_nsec = 500,
	}
	testing.expect(t, fileid.stamp_status(base, none_stamp) == .Unchanged)
	testing.expect(t, fileid.stamp_status(none_stamp, base) == .Unchanged)
	testing.expect(t, fileid.stamp_status(none_stamp, none_stamp) == .Unchanged)

	none_other := fileid.File_Stamp {
		id = fileid.FILE_ID_NONE,
		size = 99,
		mtime_sec = 1000,
		mtime_nsec = 500,
	}
	testing.expect(t, fileid.stamp_status(base, none_other) == .Changed)
	testing.expect(t, fileid.stamp_status(none_other, base) == .Changed)

	// A .None id with garbage hi/lo still compares by kind only.
	garbage_none := fileid.File_Stamp {
		id = fileid.File_ID{kind = .None, hi = 99, lo = 77},
		size = 100,
		mtime_sec = 1000,
		mtime_nsec = 500,
	}
	testing.expect(t, fileid.stamp_status(base, garbage_none) == .Unchanged)
}

@(test)
test_stamp_equal :: proc(t: ^testing.T) {
	a := fileid.File_Stamp {
		id = fileid.unix_id(1, 2),
		size = 10,
		mtime_sec = 3,
		mtime_nsec = 4,
	}
	b := a
	testing.expect(t, fileid.stamp_equal(a, b))

	b.size = 11
	testing.expect(t, !fileid.stamp_equal(a, b))
	b = a
	b.mtime_sec = 4
	testing.expect(t, !fileid.stamp_equal(a, b))
	b = a
	b.mtime_nsec = 5
	testing.expect(t, !fileid.stamp_equal(a, b))
	b = a
	b.id = fileid.unix_id(1, 3)
	testing.expect(t, !fileid.stamp_equal(a, b))

	// None ids agree with each other regardless of hi/lo, and never
	// with an identifiable id.
	n1 := fileid.File_Stamp {
		id = fileid.FILE_ID_NONE,
		size = 7,
		mtime_sec = 8,
		mtime_nsec = 9,
	}
	n2 := fileid.File_Stamp {
		id = fileid.File_ID{kind = .None, hi = 5, lo = 6},
		size = 7,
		mtime_sec = 8,
		mtime_nsec = 9,
	}
	testing.expect(t, fileid.stamp_equal(n1, n2))
	testing.expect(t, !fileid.stamp_equal(n1, a))
}

// --- Reference models (independent implementations of the policy) -----

// ref_order_key canonicalizes an id into a sort key ordered the same
// way the product's `id_cmp` orders ids, but implemented independently:
// array-lexicographic comparison instead of field branches, with .None
// mapped to the all-zero key.
ref_order_key :: proc(id: fileid.File_ID) -> [3]u64 {
	if id.kind == .None {
		return {0, 0, 0}
	}
	return {u64(id.kind), id.hi, id.lo}
}

ref_order_cmp :: proc(a, b: fileid.File_ID) -> int {
	ka, kb := ref_order_key(a), ref_order_key(b)
	for i in 0 ..< 3 {
		if ka[i] < kb[i] {
			return -1
		}
		if ka[i] > kb[i] {
			return +1
		}
	}
	return 0
}

ref_id_equal :: proc(a, b: fileid.File_ID) -> bool {
	ka, kb := ref_order_key(a), ref_order_key(b)
	for i in 0 ..< 3 {
		if ka[i] != kb[i] {
			return false
		}
	}
	return true
}

// ref_status is the independent reference for `stamp_status`: the same
// policy, structured differently — an availability switch plus a
// separate version helper, with plain struct equality as the identity
// oracle.
ref_version_equal :: proc(a, b: fileid.File_Stamp) -> bool {
	return a.size == b.size && a.mtime_sec == b.mtime_sec && a.mtime_nsec == b.mtime_nsec
}

ref_status :: proc(expected, observed: fileid.File_Stamp) -> fileid.Stamp_Status {
	e_ident := expected.id.kind != .None
	o_ident := observed.id.kind != .None
	switch {
	case e_ident && o_ident:
		if !(expected.id == observed.id) {
			return .Replaced
		}
		if ref_version_equal(expected, observed) {
			return .Unchanged
		}
		return .Changed
	case:
		if ref_version_equal(expected, observed) {
			return .Unchanged
		}
		return .Changed
	}
}

@(test)
test_differential_order :: proc(t: ^testing.T) {
	// xorshift64 — deterministic across platforms and runs.
	state: u64 = 0x1234_5678_9abc_def0
	next := proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}

	count := 250
	ids := make([dynamic]fileid.File_ID, 0, count, context.allocator)
	defer delete(ids)
	for _ in 0 ..< count {
		kind := fileid.ID_Kind(next(&state) % 3)
		append(&ids, fileid.File_ID{kind = kind, hi = next(&state), lo = next(&state)})
	}

	for i in 0 ..< count {
		for j in 0 ..< count {
			want := ref_order_cmp(ids[i], ids[j])
			got := fileid.id_cmp(ids[i], ids[j])
			testing.expectf(t, got == want, "id_cmp mismatch at (%d, %d): got %d want %d", i, j, got, want)
			testing.expectf(
				t,
				fileid.id_cmp(ids[j], ids[i]) == -got,
				"antisymmetry failed at (%d, %d)",
				i,
				j,
			)
			testing.expectf(
				t,
				(got == 0) == fileid.id_equal(ids[i], ids[j]),
				"cmp/equal agreement failed at (%d, %d)",
				i,
				j,
			)
			if got == 0 {
				testing.expectf(t, ref_id_equal(ids[i], ids[j]), "reference equal mismatch at (%d, %d)", i, j)
			}
		}
		// Transitivity over consecutive triples (a total order must be
		// transitive; the pair checks above cannot catch a cycle).
		if i + 2 < count {
			ab := fileid.id_cmp(ids[i], ids[i + 1])
			bc := fileid.id_cmp(ids[i + 1], ids[i + 2])
			ac := fileid.id_cmp(ids[i], ids[i + 2])
			if ab <= 0 && bc <= 0 {
				testing.expectf(t, ac <= 0, "transitivity failed at %d", i)
			}
		}
	}
}

@(test)
test_differential_status :: proc(t: ^testing.T) {
	// xorshift64 — deterministic across platforms and runs.
	state: u64 = 0xf00d_cafe_1337_4242
	next := proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}

	steps := 1200
	unchanged_count, changed_count, replaced_count := 0, 0, 0
	for step in 0 ..< steps {
		// Draw a random expected stamp, then mutate 0..6 randomly
		// chosen fields of the observed copy: a no-mutation draw is
		// the .Unchanged case, version-only mutations exercise
		// .Changed, and id mutations exercise .Replaced.
		kind := fileid.ID_Kind(next(&state) % 3)
		expected := fileid.File_Stamp {
			id = fileid.File_ID{kind = kind, hi = next(&state), lo = next(&state)},
			size = next(&state),
			mtime_sec = i64(next(&state)),
			mtime_nsec = u32(next(&state) % 1_000_000_000),
		}
		observed := expected
		flips := int(next(&state) % 7)
		for _ in 0 ..< flips {
			which := next(&state) % 6
			switch which {
			case 0:
				observed.id.kind = fileid.ID_Kind(next(&state) % 3)
			case 1:
				observed.id.hi = next(&state)
			case 2:
				observed.id.lo = next(&state)
			case 3:
				observed.size = next(&state)
			case 4:
				observed.mtime_sec = i64(next(&state))
			case 5:
				observed.mtime_nsec = u32(next(&state) % 1_000_000_000)
			}
		}

		got := fileid.stamp_status(expected, observed)
		want := ref_status(expected, observed)
		testing.expectf(t, got == want, "status mismatch at step %d: got %v want %v", step, got, want)

		// Reflexivity and symmetry properties on the same draw.
		testing.expectf(t, fileid.stamp_status(expected, expected) == .Unchanged, "reflexivity failed at step %d", step)
		rev := fileid.stamp_status(observed, expected)
		testing.expectf(
			t,
			(got == .Replaced) == (rev == .Replaced),
			"replace symmetry failed at step %d",
			step,
		)
		testing.expectf(
			t,
			(got == .Changed) == (rev == .Changed),
			"change symmetry failed at step %d",
			step,
		)

		switch got {
		case .Unchanged:
			unchanged_count += 1
		case .Changed:
			changed_count += 1
		case .Replaced:
			replaced_count += 1
		}
	}

	// All three classes must actually occur — a degenerate stream that
	// never hits one of them would silently test less than intended.
	testing.expect(t, unchanged_count > 0)
	testing.expect(t, changed_count > 0)
	testing.expect(t, replaced_count > 0)
}
