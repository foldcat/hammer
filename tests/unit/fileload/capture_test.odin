// Tests for the M03.02 read/capture adapter (`hammer:core/fileload`):
// stat capture into `core/fileid` values (the §11.1 step 2
// checkpoint), the `.None` conventions from docs/m03-01-fileid.md,
// and the chunked load with its all-or-nothing and no-torn-content
// guarantees. Real files live in the task-owned sandbox; the oracle
// stamps are built independently from `os.stat` (a different syscall
// path than the handle-based fstat the adapter uses).
package fileload_test

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import fileid "hammer:core/fileid"
import fileload "hammer:core/fileload"

// stamp_from_stat is the independent oracle: a File_Stamp built from
// os.stat fields (path-based stat) with an independent copy of the
// sec/nsec split. Comparing it against the adapter's handle-fstat
// capture is the "captured stamps match fresh stats" acceptance.
stamp_from_stat :: proc(fi: os.File_Info) -> fileid.File_Stamp {
	t := time.to_unix_nanoseconds(fi.modification_time)
	sec := t / 1_000_000_000
	nsec := t % 1_000_000_000
	if nsec < 0 {
		nsec += 1_000_000_000
		sec -= 1
	}
	stamp, _ := fileid.make_stamp(
		fileload.platform_id(u64(fi.device), u64(fi.inode)),
		u64(fi.size),
		sec,
		u32(nsec),
	)
	return stamp
}

@(test)
test_capture_matches_fresh_stat :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("capture-basic.txt")
	content := "hello, hammer\nünïcode ✓ αβγ\n"
	expect_ok(t, os.write_entire_file(path, transmute([]byte)content))
	defer os.remove_all(path)

	cap, err := fileload.capture_file(path, context.allocator)
	expect_ok(t, err)

	// A sandbox file on a real filesystem is identifiable.
	testing.expect(t, !fileid.is_none(cap.id))
	testing.expect(t, cap.stamp.size == u64(len(content)))

	// Independent oracle: path-based stat.
	fi, serr := os.stat(path, context.allocator)
	expect_ok(t, serr)
	defer os.file_info_delete(fi, context.allocator)
	testing.expect(t, fileid.stamp_equal(cap.stamp, stamp_from_stat(fi)))
	testing.expect(t, fileid.id_equal(cap.id, fileload.platform_id(u64(fi.device), u64(fi.inode))))
}

@(test)
test_capture_error_paths :: proc(t: ^testing.T) {
	sandbox_init(t)
	missing := sandbox_path("capture-missing.txt")
	os.remove_all(missing)

	_, err := fileload.capture_file(missing, context.allocator)
	testing.expect(t, err.kind == .NotFound)
	errs.destroy(&err)

	when ODIN_OS == .Linux {
		// Directories open on Linux, so the regular-file policy is
		// what rejects them (on Windows os.open fails first — the
		// Wine consumer exercises that branch).
		dir := sandbox_path("capture-dir")
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		_, err2 := fileload.capture_file(dir, context.allocator)
		testing.expect(t, err2.kind == .Unsupported)
		errs.destroy(&err2)
	}
}

@(test)
test_capture_none_conventions :: proc(t: ^testing.T) {
	// inode 0 (Unix) / file index 0 (Windows) -> the canonical .None,
	// on both platforms — the m03-01-fileid.md convention.
	c0, e0 := fileload.capture_from_stat(7, 0, 123, time.Time{}, context.allocator)
	testing.expect(t, errs.ok(e0))
	testing.expect(t, fileid.is_none(c0.id))
	testing.expect(t, fileid.id_equal(c0.id, fileid.FILE_ID_NONE))
	// The version passes through even when the identity is .None.
	testing.expect(t, c0.stamp.size == 123)

	// A zero device / volume serial with a nonzero inode/index is
	// kept as-is (real anonymous devices / volumes), never invalidated.
	c1, e1 := fileload.capture_from_stat(0, 9, 5, time.Time{}, context.allocator)
	testing.expect(t, errs.ok(e1))
	testing.expect(t, !fileid.is_none(c1.id))
	testing.expect(t, c1.id.hi == 0 && c1.id.lo == 9)

	// A negative size is external data: .Invalid_Input, never an assert.
	_, e2 := fileload.capture_from_stat(1, 2, -1, time.Time{}, context.allocator)
	testing.expect(t, e2.kind == .Invalid_Input)
	errs.destroy(&e2)
}

@(test)
test_capture_mtime_split :: proc(t: ^testing.T) {
	// Positive times split straightforwardly.
	c1, e1 := fileload.capture_from_stat(1, 2, 0, time.Time{_nsec = 3_000_000_001}, context.allocator)
	testing.expect(t, errs.ok(e1))
	testing.expect(t, c1.stamp.mtime_sec == 3 && c1.stamp.mtime_nsec == 1)

	// Negative times (before 1970, valid on FAT) floor to the
	// previous second with a non-negative fraction.
	c2, e2 := fileload.capture_from_stat(1, 2, 0, time.Time{_nsec = -1}, context.allocator)
	testing.expect(t, errs.ok(e2))
	testing.expect(t, c2.stamp.mtime_sec == -1 && c2.stamp.mtime_nsec == 999_999_999)

	// Exact second boundary.
	c3, e3 := fileload.capture_from_stat(1, 2, 0, time.Time{_nsec = -1_000_000_000}, context.allocator)
	testing.expect(t, errs.ok(e3))
	testing.expect(t, c3.stamp.mtime_sec == -1 && c3.stamp.mtime_nsec == 0)
}

@(test)
test_load_chunked_roundtrip :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-multi.txt")

	// Patterned content spanning many chunks: multibyte scalars,
	// CRLF pairs, and enough bytes to force chunk boundary splits.
	content: [dynamic]u8
	defer delete(content)
	for i in 0 ..< 10 {
		line := fmt.tprintf("line %v: ünïcode ✓ αβγ δειγμα\r\n", i)
		append(&content, ..transmute([]u8)line)
	}
	expect_ok(t, os.write_entire_file(path, content[:]))
	defer os.remove_all(path)

	loaded: fileload.Loaded
	expect_ok(t, fileload.load_file(&loaded, path, {chunk_size = 64}, context.allocator))
	defer fileload.loaded_destroy(&loaded)

	// The chunk ids concatenate to the file bytes exactly.
	got := concat_chunks(&loaded)
	defer delete(got)
	testing.expectf(
		t,
		bytes.equal(got, content[:]),
		"content mismatch: got %v bytes, want %v",
		len(got),
		len(content),
	)

	// Every chunk honors the chunk_size bound.
	for id in loaded.ids {
		testing.expect(t, len(chunk.data(&loaded.store, id)) <= 64)
	}

	// The captured stamp matches a fresh stat of the same file.
	fi, serr := os.stat(path, context.allocator)
	expect_ok(t, serr)
	defer os.file_info_delete(fi, context.allocator)
	testing.expect(t, fileid.stamp_equal(loaded.capture.stamp, stamp_from_stat(fi)))
	testing.expect(t, loaded.capture.stamp.size == u64(len(content)))
}

@(test)
test_load_empty_file :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-empty.txt")
	expect_ok(t, os.write_entire_file(path, []u8{}))
	defer os.remove_all(path)

	loaded: fileload.Loaded
	expect_ok(t, fileload.load_file(&loaded, path, {}, context.allocator))
	defer fileload.loaded_destroy(&loaded)

	testing.expect(t, len(loaded.ids) == 0)
	testing.expect(t, loaded.capture.stamp.size == 0)
	testing.expect(t, !fileid.is_none(loaded.capture.id))
}

@(test)
test_load_interns_repeated_chunks :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-dedup.txt")

	// Eight identical 64-byte chunks: regular-file reads fill the
	// buffer, so each read interns the same 64 bytes — one stored
	// chunk, eight id-list entries.
	content := make([]u8, 8 * 64, context.allocator)
	defer delete(content)
	for i in 0 ..< len(content) {
		content[i] = 'x'
	}
	expect_ok(t, os.write_entire_file(path, content))
	defer os.remove_all(path)

	loaded: fileload.Loaded
	expect_ok(t, fileload.load_file(&loaded, path, {chunk_size = 64}, context.allocator))
	defer fileload.loaded_destroy(&loaded)

	testing.expect(t, len(loaded.ids) == 8)
	testing.expect(t, chunk.chunk_count(&loaded.store) == 1)
	testing.expect(t, chunk.total_bytes(&loaded.store) == 64)
	for id in loaded.ids[1:] {
		testing.expect(t, id == loaded.ids[0])
	}

	got := concat_chunks(&loaded)
	defer delete(got)
	testing.expect(t, bytes.equal(got, content))
}

@(test)
test_load_error_paths :: proc(t: ^testing.T) {
	sandbox_init(t)

	// Missing file: .NotFound, nothing to destroy.
	missing := sandbox_path("load-missing.txt")
	os.remove_all(missing)
	loaded: fileload.Loaded
	err := fileload.load_file(&loaded, missing, {}, context.allocator)
	testing.expect(t, err.kind == .NotFound)
	testing.expect(t, loaded.ids == nil)
	testing.expect(t, chunk.chunk_count(&loaded.store) == 0)
	errs.destroy(&err)

	when ODIN_OS == .Linux {
		// A directory opens but is not a regular file: .Unsupported.
		dir := sandbox_path("load-dir")
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		loaded2: fileload.Loaded
		err2 := fileload.load_file(&loaded2, dir, {}, context.allocator)
		testing.expect(t, err2.kind == .Unsupported)
		errs.destroy(&err2)
	}
}

@(test)
test_load_cancelled_before_start :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-cancel.txt")
	expect_ok(t, os.write_entire_file(path, []u8{'h', 'i'}))
	defer os.remove_all(path)

	// A set cancellation flag aborts the load at the first chunk
	// boundary check — deterministically .Cancelled.
	cancel := true
	loaded: fileload.Loaded
	err := fileload.load_file(&loaded, path, {}, context.allocator, &cancel)
	testing.expect(t, err.kind == .Cancelled)
	errs.destroy(&err)
	// All-or-nothing: the partial state was destroyed.
	testing.expect(t, loaded.ids == nil)
}

// Modifier_State drives the concurrent-writer property test: a
// modifier thread flips the file between two complete contents while
// the test loads it. `stop` is atomic (join provides the final
// happens-before edge).
Modifier_State :: struct {
	path:      string,
	content_a: []u8,
	content_b: []u8,
	stop:      bool,
}

// modifier_proc drives the concurrent-writer property test: a
// modifier thread flips the file between two complete contents via
// atomic temp+rename while the test loads it — the file only ever
// holds a complete state. `stop` is atomic (join provides the final
// happens-before edge).
modifier_proc :: proc(t: ^thread.Thread) {
	s := cast(^Modifier_State)t.data
	tmp := fmt.tprintf("%s.tmp", s.path)
	flip := false
	for !sync.atomic_load(&s.stop) {
		if flip {
			_ = os.write_entire_file(tmp, s.content_b)
			_ = os.rename(tmp, s.path)
		} else {
			_ = os.write_entire_file(tmp, s.content_a)
			_ = os.rename(tmp, s.path)
		}
		flip = !flip
		time.sleep(1 * time.Millisecond)
	}
}

// modifier_inplace_proc is the in-place variant: truncate+write,
// which makes the file pass through a momentary empty state.
modifier_inplace_proc :: proc(t: ^thread.Thread) {
	s := cast(^Modifier_State)t.data
	flip := false
	for !sync.atomic_load(&s.stop) {
		if flip {
			_ = os.write_entire_file(s.path, s.content_b)
		} else {
			_ = os.write_entire_file(s.path, s.content_a)
		}
		flip = !flip
		time.sleep(1 * time.Millisecond)
	}
}

// test_load_never_torn_by_concurrent_write: while a modifier thread
// flips the file between two complete contents via atomic
// temp+rename, every load must succeed with one of the two complete
// contents (the open handle pins an inode, so a mid-load rename is
// invisible and the snapshot is always one complete state). The
// assertion is invariant-based — any interleaving passes — and fails
// only if a load produces content that matches neither state.
@(test)
test_load_never_torn_by_concurrent_write :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-race.txt")
	os.remove_all(fmt.tprintf("%s.tmp", path))

	content_a := make([]u8, 256 * 1024, context.allocator)
	defer delete(content_a)
	content_b := make([]u8, 256 * 1024, context.allocator)
	defer delete(content_b)
	for i in 0 ..< len(content_a) {
		content_a[i] = u8((i * 31 + 7) % 251)
		content_b[i] = u8((i * 17 + 3) % 239)
	}
	expect_ok(t, os.write_entire_file(path, content_a))
	defer os.remove_all(path)
	defer os.remove_all(fmt.tprintf("%s.tmp", path))

	state := Modifier_State{path = path, content_a = content_a, content_b = content_b}
	modifier := thread.create(modifier_proc)
	modifier.data = &state
	thread.start(modifier)

	for round in 0 ..< 200 {
		loaded: fileload.Loaded
		err := fileload.load_file(&loaded, path, {chunk_size = 4096}, context.allocator)
		testing.expectf(t, errs.ok(err), "round %v: unexpected error kind %v", round, err.kind)
		if !errs.ok(err) {
			errs.destroy(&err)
			continue
		}
		got := concat_chunks(&loaded)
		testing.expectf(
			t,
			bytes.equal(got, content_a) || bytes.equal(got, content_b),
			"round %v: torn content (%v bytes that match neither complete state)",
			round,
			len(got),
		)
		// A successful load is a self-consistent snapshot: the bytes
		// read match the stamp's size.
		testing.expectf(
			t,
			u64(len(got)) == loaded.capture.stamp.size,
			"round %v: content/stamp mismatch (%v bytes vs stamp size %v)",
			round,
			len(got),
			loaded.capture.stamp.size,
		)
		delete(got)
		fileload.loaded_destroy(&loaded)
	}

	sync.atomic_store(&state.stop, true)
	thread.join(modifier)
	thread.destroy(modifier)
}

// test_load_conflict_or_consistent_under_inplace_write: the same
// invariant for an in-place truncate+write modifier. The file passes
// through a momentary empty state, so a successful load may see a, b,
// or — if its whole window landed between the truncate and the write
// — the empty state; a load whose window straddles a write fails with
// .Conflict. Every success must be a self-consistent snapshot
// (content length == stamp size); anything else is a torn load.
@(test)
test_load_conflict_or_consistent_under_inplace_write :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := sandbox_path("load-race-inplace.txt")

	content_a := make([]u8, 128 * 1024, context.allocator)
	defer delete(content_a)
	content_b := make([]u8, 128 * 1024, context.allocator)
	defer delete(content_b)
	for i in 0 ..< len(content_a) {
		content_a[i] = u8((i * 29 + 11) % 253)
		content_b[i] = u8((i * 13 + 5) % 241)
	}
	expect_ok(t, os.write_entire_file(path, content_a))
	defer os.remove_all(path)

	state := Modifier_State{path = path, content_a = content_a, content_b = content_b}
	modifier := thread.create(modifier_inplace_proc)
	modifier.data = &state
	thread.start(modifier)

	successes := 0
	conflicts := 0
	for round in 0 ..< 300 {
		loaded: fileload.Loaded
		err := fileload.load_file(&loaded, path, {chunk_size = 4096}, context.allocator)
		if errs.ok(err) {
			got := concat_chunks(&loaded)
			testing.expectf(
				t,
				bytes.equal(got, content_a) || bytes.equal(got, content_b) || len(got) == 0,
				"round %v: torn content (%v bytes that match neither complete state nor the empty truncate window)",
				round,
				len(got),
			)
			testing.expectf(
				t,
				u64(len(got)) == loaded.capture.stamp.size,
				"round %v: content/stamp mismatch (%v bytes vs stamp size %v)",
				round,
				len(got),
				loaded.capture.stamp.size,
			)
			delete(got)
			fileload.loaded_destroy(&loaded)
			successes += 1
		} else {
			testing.expectf(t, err.kind == .Conflict, "round %v: got %v, want .Conflict", round, err.kind)
			errs.destroy(&err)
			conflicts += 1
		}
	}

	sync.atomic_store(&state.stop, true)
	thread.join(modifier)
	thread.destroy(modifier)

	// Both classes must actually be exercised — a test that only ever
	// sees one of them is not testing the conflict contract.
	testing.expectf(t, successes > 0, "no successful load in 300 rounds")
	testing.expectf(t, conflicts > 0, "no .Conflict load in 300 rounds")
}
