// Package fileid: canonical file identity (M03.01, SPECS.md §6.4) and
// version-validated identity for external-change detection (SPECS.md
// §11.1 step 2, §11.2).
//
// A file is identified twice over:
//
//   - `File_ID` — the platform file identity: device/inode on Unix,
//     volume-serial/file-index on Windows. Two spellings of one path
//     (`foo.c`, `./foo.c`, `/proj/foo.c`, a symlink to it, a hard link
//     to it) share one `File_ID`, so a buffer registry can dedup them
//     (SPECS.md §6.4). When the platform reports no usable identity
//     (POSIX inode 0, Windows file index 0), the id is `.None` — a
//     single canonical "not identifiable" value, never a dedup key.
//
//   - `File_Stamp` — a *versioned* identity: `File_ID` plus byte size
//     plus mtime. A stamp is captured when a buffer is loaded and
//     re-recorded after each successful save (§11.1 steps 2 and 8);
//     `stamp_status` classifies a freshly observed stamp against the
//     recorded one (`.Unchanged` / `.Changed` / `.Replaced`), which is
//     the input to M03.06 disk-change conflict detection. Size and
//     mtime alone are the classic check, but only the id distinguishes
//     "modified in place" from "replaced by another file".
//
// This package is headless and backend-free (SPECS.md §4.2): it models
// and validates identity values but performs **no file I/O**. There is
// no file I/O architecture yet (NEXT.md M03.01): the stat capture
// adapters land with M03.02 (background loading) and M03.06 (change
// detection), and canonical *path* resolution (realpath / Windows
// GetFinalPathNameByHandle) needs the same adapters — this slice
// deliberately stops at the values and the comparison policy.
//
// Contracts (AGENTS.md §10):
//
//   - All values are plain structs; nothing here allocates except the
//     error message on `make_stamp` failure (caller's allocator,
//     destroy with `errs.destroy`).
//   - All inputs are treated as external data (AGENTS.md §11.2): no
//     assertion anywhere. Invalid values surface as `.Invalid_Input`
//     or are mapped onto the documented `.None` sentinel.
package fileid

import errs "../errs"

// ID_Kind names the identity space a File_ID was captured in. Two ids
// from different spaces never compare equal (and a cross-kind
// stamp comparison classifies as `.Replaced`).
ID_Kind :: enum {
	None, // no identity available (stat failed, inode 0, file index 0, ...)
	Unix, // device (st_dev) + inode (st_ino)
	Windows, // volume serial + 64-bit file index
}

// File_ID is the platform file identity (SPECS.md §6.4).
//
// Field layout per kind:
//
//	Unix:    hi = st_dev (device), lo = st_ino (inode)
//	Windows: hi = volume serial number, zero-extended from u32;
//	         lo = 64-bit file index (nFileIndexHigh/Low combined)
//
// A `.None` id is a single canonical value: `hi`/`lo` are meaningless
// and ignored by every comparison. Never use a `.None` id as a
// registry/dedup key — two different unidentifiable files would
// collide (the M03.06 capture layer must fall back to path identity
// there).
File_ID :: struct {
	kind: ID_Kind,
	hi:   u64,
	lo:   u64,
}

// FILE_ID_NONE is the canonical "no identity" id.
FILE_ID_NONE :: File_ID{}

// unix_id builds a Unix identity from stat fields. An inode of 0 means
// the inode number is not known (POSIX: st_ino == 0 is never a valid
// file) and maps to `.None`; a zero device with a nonzero inode is
// kept as-is (st_dev == 0 occurs on anonymous devices and is not
// structurally invalid here).
unix_id :: proc(dev, ino: u64) -> File_ID {
	if ino == 0 {
		return FILE_ID_NONE
	}
	return File_ID{kind = .Unix, hi = dev, lo = ino}
}

// windows_id builds a Windows identity from BY_HANDLE_FILE_INFORMATION
// fields. A file index of 0 means the filesystem provides no stable
// identity and maps to `.None` (dwVolumeSerialNumber alone can be 0 on
// real volumes and is not treated as invalid).
windows_id :: proc(volume_serial: u32, file_index: u64) -> File_ID {
	if file_index == 0 {
		return FILE_ID_NONE
	}
	return File_ID{kind = .Windows, hi = u64(volume_serial), lo = file_index}
}

// is_none reports whether `id` carries no usable identity.
is_none :: proc(id: File_ID) -> bool {
	return id.kind == .None
}

// id_equal reports whether `a` and `b` name the same platform identity.
// Two `.None` ids are always equal (the canonical-value rule); `.None`
// never equals an identifiable id.
id_equal :: proc(a, b: File_ID) -> bool {
	if a.kind == .None || b.kind == .None {
		return a.kind == .None && b.kind == .None
	}
	return a.kind == b.kind && a.hi == b.hi && a.lo == b.lo
}

// id_cmp imposes a total order on File_IDs: `.None` sorts first, then
// by kind, then device/serial (`hi`), then inode/index (`lo`). The
// order satisfies `id_cmp(a, b) == 0` exactly when `id_equal(a, b)`
// (pinned by the differential tests), so it is safe for sort-based
// registries and dedup.
id_cmp :: proc(a, b: File_ID) -> int {
	if a.kind == .None || b.kind == .None {
		if a.kind == .None && b.kind == .None {
			return 0
		}
		return a.kind == .None ? -1 : +1
	}
	if a.kind != b.kind {
		return a.kind < b.kind ? -1 : +1
	}
	if a.hi != b.hi {
		return a.hi < b.hi ? -1 : +1
	}
	if a.lo != b.lo {
		return a.lo < b.lo ? -1 : +1
	}
	return 0
}

// File_Stamp is a version-validated identity: the platform identity
// plus the size/mtime version that external-change detection compares
// (SPECS.md §11.1, §11.2). A stamp is what a buffer records at load
// and after each successful save, and what a fresh stat produces to
// validate against.
//
// The version is size + mtime only (no ctime): ctime would flag
// metadata touches that do not change content (chmod, utimes by
// backup tools), and the id already catches replacement. A change to
// content without any size/mtime change is a policy question for the
// capture layer (M03.06), not something the stamp model can see.
File_Stamp :: struct {
	id:         File_ID,
	size:       u64, // byte size of the file
	mtime_sec:  i64, // any value: negative = before 1970, valid on FAT etc.
	mtime_nsec: u32, // fraction of a second: 0 <= nsec < 1_000_000_000
}

// NSECS_PER_SEC bounds `mtime_nsec`.
NSECS_PER_SEC :: 1_000_000_000

// make_stamp validates raw stat fields into a File_Stamp. `mtime_nsec`
// must be in [0, NSECS_PER_SEC) (`.Invalid_Input` otherwise); size and
// mtime_sec are structurally unconstrained (any u64/i64 from a stat is
// plausible external data — do not assert on it, AGENTS.md §11.2).
make_stamp :: proc(
	id: File_ID,
	size: u64,
	mtime_sec: i64,
	mtime_nsec: u32,
) -> (File_Stamp, errs.Error) {
	if mtime_nsec >= NSECS_PER_SEC {
		return {}, errs.newf(
			.Invalid_Input,
			"fileid: invalid mtime_nsec %d (0 <= nsec < %d expected)",
			mtime_nsec,
			NSECS_PER_SEC,
		)
	}
	return File_Stamp{id = id, size = size, mtime_sec = mtime_sec, mtime_nsec = mtime_nsec}, {}
}

// Stamp_Status classifies an observed stamp against a recorded one —
// the vocabulary for M03.06 conflict detection and for the §11.1
// pre-save validation step.
Stamp_Status :: enum {
	Unchanged, // same identity, same size+mtime: safe to save in place
	Changed, // same identity (or identity unverifiable), size/mtime differ:
	// the file was modified externally
	Replaced, // different identity: the path now names a different file
}

// stamp_status compares a freshly observed stamp against the one
// recorded at load/save time.
//
// Policy (pinned by the differential tests):
//
//  1. If both identities are available and differ, the result is
//     `.Replaced` — including cross-kind ids, which never compare
//     equal. Same identity falls through to the version check.
//  2. If either identity is `.None` (the file was loaded from a
//     filesystem without stable ids, or the fresh stat has none), the
//     identity cannot be validated: the comparison degrades to the
//     size+mtime version check and never reports `.Replaced`. This is
//     documented best effort — a same-size-same-mtime replacement is
//     undetectable without identity, and the caller decides what
//     `.Unchanged` is worth on such filesystems.
stamp_status :: proc(expected, observed: File_Stamp) -> Stamp_Status {
	e_ok := expected.id.kind != .None
	o_ok := observed.id.kind != .None
	if e_ok && o_ok && !id_equal(expected.id, observed.id) {
		return .Replaced
	}
	if version_equal(expected, observed) {
		return .Unchanged
	}
	return .Changed
}

// stamp_equal reports whether two stamps agree on every field — the
// checkpoint comparison for "the disk still carries exactly the stamp
// I recorded" (§11.1 step 8). Two `.None` ids compare equal under
// `id_equal`, so stamps agree on identity whenever both sides lack it.
stamp_equal :: proc(a, b: File_Stamp) -> bool {
	return id_equal(a.id, b.id) && version_equal(a, b)
}

// version_equal is the id-insensitive size+mtime comparison.
version_equal :: proc(a, b: File_Stamp) -> bool {
	return a.size == b.size && a.mtime_sec == b.mtime_sec && a.mtime_nsec == b.mtime_nsec
}

// Case_Sensitivity records the case behavior of the filesystem holding
// a buffer (SPECS.md §6.4). `.Unknown` is the honest default — do not
// assume Unix paths are case-sensitive or Windows paths
// case-insensitive; the M03.02 capture layer probes/records the actual
// volume behavior before any case-folding path comparison.
Case_Sensitivity :: enum {
	Unknown,
	Case_Sensitive,
	Case_Insensitive,
}

// Symlink_Policy records how a buffer treats the path it was opened by
// (SPECS.md §6.4, §11.1 "define policies for symlinks"):
//
//   - `.Follow`: the buffer's identity is the link *target's* identity
//     (stat, not lstat), so `./foo.c` and a symlink to it dedup; the
//     display path may still be the link. Save semantics through a
//     symlink are decided in M03.05 and are not implied here.
//   - `.Preserve_Link`: the identity is the link itself (lstat); the
//     link path is the canonical path, and a second path naming the
//     target is a different buffer.
//
// Which policy applies is captured by the load/save adapters; this
// package only defines the tracked attribute.
Symlink_Policy :: enum {
	Follow,
	Preserve_Link,
}
