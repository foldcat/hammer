// Package fileload: file capture and chunked loading (M03.02,
// SPECS.md §6.4, §7.5, §11.1 step 2).
//
// This is the read/capture adapter that turns real files into the two
// things the editor needs when a buffer is opened:
//
//   - `Capture` — the platform identity and version of the file
//     (`fileid.File_ID` + `fileid.File_Stamp`), taken from the same
//     handle the content is read through: on Unix, st_dev/st_ino from
//     statx on the opened fd; on Windows, the volume serial / 64-bit
//     file index from `GetFileInformationByHandle`. This is the
//     §11.1 step 2 checkpoint: the buffer records it at load time and
//     after every successful save, and M03.06 compares a fresh
//     capture against it with `fileid.stamp_status`.
//   - `Loaded` — the file's content, read in bounded `chunk_size`
//     chunks and interned into a fresh M02 `core/chunk` store
//     (SPECS.md §7.5 "chunked background loading"), plus the ordered
//     chunk id list whose concatenation reproduces the file bytes —
//     the input the rope builder consumes. `Loader` (loader.odin)
//     runs the same load on one background worker thread with bounded
//     queues (SPECS.md §4.4).
//
// Identity policy (docs/m03-01-fileid.md, pinned by its
// differentials):
//
//   - `.None` is one canonical value: inode 0 (Unix) / file index 0
//     (Windows) map to `fileid.FILE_ID_NONE`. Never use it as a
//     registry key — the M03.06 capture layer falls back to path
//     identity for unidentifiable files.
//   - A zero device / zero volume serial is *not* invalidated (both
//     occur on real devices/volumes); only the inode/index zero
//     convention is encoded.
//   - Symlinks are followed (the identity is the target's):
//     `Symlink_Policy.Follow` is this layer's behavior;
//     `.Preserve_Link` semantics are M03.05's decision.
//
// Load-time consistency: `load_file` captures the stamp before
// reading and re-stats the same handle after the last chunk. If id,
// size, or mtime changed during the load, the result is `.Conflict`
// and nothing is returned — a concurrent writer cannot produce a torn
// snapshot. A same-size-same-mtime rewrite is undetectable without
// stronger locking; that is the same documented best effort as the
// fileid model, and the caller's policy decision (M03.06).
//
// Bounds and safety:
//
//   - Only regular files load. Directories, devices, FIFOs, and
//     sockets are rejected (`.Unsupported`) by a type check before
//     any read (on Linux the open itself is O_NONBLOCK, so a FIFO
//     can neither block the caller forever nor make the read loop
//     spin, and /dev/zero cannot read forever).
//   - Load memory is one `chunk_size` read buffer plus the interned
//     content (the store grows with the file by design — the loaded
//     text lives in memory; large-file policy is §7.5/M03.07).
//   - A cancellation flag (worker-owned, checked atomically between
//     chunks) aborts the read loop with `.Cancelled`.
//
// Contracts (AGENTS.md §10):
//
//   - `Loaded` contains a `chunk.Store` and dynamic arrays: it is a
//     fixed-location value — pass by pointer, never copy it. All its
//     storage is allocated with the allocator passed to `load_file`;
//     release with `loaded_destroy`. On error the partial store is
//     destroyed before returning (all-or-nothing): a failed load
//     leaves `*loaded` zero, with nothing to destroy.
//   - Error messages use the caller's allocator; destroy with
//     `errs.destroy`.
//   - Headless and backend-free (SPECS.md §4.2): `core:os` only —
//     raw syscalls on Linux, Win32/HeapAlloc on Windows — plus
//     `core:sync` atomics; no CRT, no Sokol. Builds under `-no-crt`.
package fileload

import "core:mem"
import "core:os"
import "core:sync"
import "core:time"

import chunk "../chunk"
import errs "../errs"
import fileid "../fileid"

// NSECS_PER_SEC bounds the stamp's mtime fraction.
NSECS_PER_SEC :: 1_000_000_000

// Capture is the §11.1 step 2 checkpoint: the platform identity plus
// the version (size + mtime) observed at a specific point in time.
// Plain data; safe to copy and compare.
Capture :: struct {
	id:    fileid.File_ID,
	stamp: fileid.File_Stamp,
}

// Load_Options configures a chunked load.
Load_Options :: struct {
	// chunk_size is the read/interning granularity (0 selects
	// chunk.DEFAULT_CHUNK_SIZE). It must not be negative (asserted —
	// a programmer invariant, not external input).
	chunk_size: int,
}

// Loaded is the result of a successful chunked load. Fixed-location
// value: pass by pointer, never copy it (duplicating the store and
// array headers corrupts state — the M02.06 trap).
Loaded :: struct {
	capture: Capture, // §11.1 step 2 checkpoint, captured at load time
	store:   chunk.Store, // owned; the interned file content
	ids:     [dynamic]chunk.Chunk_ID, // owned; concat(store.data(ids[i])) == file bytes
}

// platform_id maps raw stat identity fields onto the canonical
// File_ID: inode 0 (Unix) / file index 0 (Windows) become `.None`
// (the documented conventions), a zero device/serial passes through.
platform_id :: proc(dev: u64, ino: u64) -> fileid.File_ID {
	when ODIN_OS == .Linux {
		return fileid.unix_id(dev, ino)
	} else when ODIN_OS == .Windows {
		return fileid.windows_id(u32(dev), ino)
	} else {
		#panic("fileload: unsupported platform")
	}
}

// capture_from_stat converts raw fstat fields into a Capture. The
// size must not be negative (`.Invalid_Input`); the mtime passes
// through unconstrained — negative times (before 1970) are valid on
// FAT and are floored into sec/nsec. This proc is also the unit-test
// seam for the `.None` conventions and the time split.
capture_from_stat :: proc(
	dev: u64,
	ino: u64,
	size: i64,
	mtime: time.Time,
	allocator := context.allocator,
) -> (cap: Capture, err: errs.Error) {
	if size < 0 {
		return {}, errs.newf(
			.Invalid_Input,
			"fileload: negative file size %v",
			size,
			allocator = allocator,
		)
	}
	t := time.to_unix_nanoseconds(mtime)
	sec := t / NSECS_PER_SEC
	nsec := t % NSECS_PER_SEC
	if nsec < 0 {
		nsec += NSECS_PER_SEC
		sec -= 1
	}
	id := platform_id(dev, ino)
	stamp, serr := fileid.make_stamp(id, u64(size), sec, u32(nsec))
	if !errs.ok(serr) {
		return {}, serr
	}
	return Capture{id = id, stamp = stamp}, {}
}

// open_error maps an os error into a structured error. `.Not_Exist`
// (ENOENT / ERROR_FILE_NOT_FOUND) is the `.NotFound` contract;
// everything else is `.IO` with the platform error in the message.
open_error :: proc(path: string, oerr: os.Error, allocator := context.allocator) -> errs.Error {
	if oerr == .Not_Exist {
		return errs.newf(.NotFound, "fileload: %s: file not found", path, allocator = allocator)
	}
	return errs.newf(.IO, "fileload: %s: cannot open: %v", path, oerr, allocator = allocator)
}

// stat_error maps an fstat failure to `.IO`.
stat_error :: proc(path: string, serr: os.Error, allocator := context.allocator) -> errs.Error {
	return errs.newf(.IO, "fileload: %s: cannot stat: %v", path, serr, allocator = allocator)
}

// open_readonly opens a path for reading. On Linux the open is
// O_NONBLOCK so a FIFO cannot block the caller; on Windows the
// Non_Blocking flag maps to FILE_FLAG_OVERLAPPED, which breaks
// `os.read` (NULL OVERLAPPED) — and there is no equivalent blocking
// hazard: named pipes are not reachable through a plain path open,
// and non-regular files are rejected by the type check before any
// read happens.
open_readonly :: proc(path: string) -> (f: ^os.File, err: os.Error) {
	when ODIN_OS == .Linux {
		return os.open(path, {.Read, .Non_Blocking})
	} else {
		return os.open(path, {.Read})
	}
}

// capture_file opens `path` read-only and captures its platform
// identity and version from the open handle (fstat, not path stat —
// no TOCTOU: the identity names the file the handle is bound to,
// not whatever the path resolves to a moment later). Only regular
// files capture (`.Unsupported` otherwise).
capture_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (cap: Capture, err: errs.Error) {
	f, oerr := open_readonly(path)
	if oerr != nil {
		return {}, open_error(path, oerr, allocator)
	}
	defer os.close(f)

	fi, ferr := os.fstat(f, allocator)
	if ferr != nil {
		return {}, stat_error(path, ferr, allocator)
	}
	defer os.file_info_delete(fi, allocator)

	if fi.type != .Regular {
		return {}, errs.newf(
			.Unsupported,
			"fileload: %s is not a regular file",
			path,
			allocator = allocator,
		)
	}
	return capture_from_stat(
		u64(fi.device),
		u64(fi.inode),
		fi.size,
		fi.modification_time,
		allocator,
	)
}

// load_file opens `path` read-only, captures the §11.1 step 2
// checkpoint, reads the content in `chunk_size` chunks interning each
// into a fresh chunk store, and verifies the file did not change
// while it was read (id/size/mtime re-checked on the same handle —
// `.Conflict` otherwise, with the partial load discarded).
//
// - On success `loaded` owns the store and the id list (the ids
//   concatenate to the file bytes); `loaded.capture` is the stamp
//   recorded at load time. Release with `loaded_destroy`.
// - On error `*loaded` is zero (all-or-nothing) and the error is
//   owned by the caller.
// - `cancel` (nil = never cancelled) is checked atomically between
//   chunks: when set, the load aborts with `.Cancelled`. The loader
//   passes its worker flag; synchronous callers pass nil.
// - Empty files load successfully: empty store, empty id list, and a
//   valid size-0 stamp.
load_file :: proc(
	loaded: ^Loaded,
	path: string,
	options: Load_Options,
	allocator := context.allocator,
	cancel: ^bool = nil,
) -> errs.Error {
	chunk_size := options.chunk_size
	if chunk_size == 0 {
		chunk_size = chunk.DEFAULT_CHUNK_SIZE
	}
	assert(chunk_size > 0, "fileload: options.chunk_size must not be negative")

	f, oerr := open_readonly(path)
	if oerr != nil {
		return open_error(path, oerr, allocator)
	}
	defer os.close(f)

	fi, ferr := os.fstat(f, allocator)
	if ferr != nil {
		return stat_error(path, ferr, allocator)
	}
	defer os.file_info_delete(fi, allocator)

	if fi.type != .Regular {
		return errs.newf(
			.Unsupported,
			"fileload: %s is not a regular file",
			path,
			allocator = allocator,
		)
	}

	cap, cerr := capture_from_stat(
		u64(fi.device),
		u64(fi.inode),
		fi.size,
		fi.modification_time,
		allocator,
	)
	if !errs.ok(cerr) {
		return cerr
	}

	chunk.init(&loaded.store, {chunk_size = chunk_size}, allocator)
	loaded.ids = make([dynamic]chunk.Chunk_ID, allocator)
	// Explicit free with the creating allocator: `delete` on a
	// []byte goes through context.allocator, not the slice's own
	// (the M02.08 trap).
	buf := make([]byte, chunk_size, allocator)
	defer mem.free(raw_data(buf), allocator)

	for {
		if cancel != nil && sync.atomic_load(cancel) {
			loaded_destroy(loaded)
			return errs.newf(
				.Cancelled,
				"fileload: %s: load cancelled",
				path,
				allocator = allocator,
			)
		}
		n, rerr := os.read(f, buf)
		if n == 0 {
			// EOF; a zero read with no error cannot happen on a
			// regular file — treat it as the end defensively (the
			// post-load stamp check below catches truncation).
			if rerr == .EOF || rerr == nil {
				break
			}
			loaded_destroy(loaded)
			return errs.newf(
				.IO,
				"fileload: %s: read failed: %v",
				path,
				rerr,
				allocator = allocator,
			)
		}
		if rerr != nil {
			// Data followed by an error: the snapshot is torn.
			loaded_destroy(loaded)
			return errs.newf(
				.IO,
				"fileload: %s: read failed: %v",
				path,
				rerr,
				allocator = allocator,
			)
		}
		id, aerr := chunk.intern(&loaded.store, buf[:n])
		if aerr != .None {
			loaded_destroy(loaded)
			return errs.newf(
				.Resource_Limit,
				"fileload: %s: interning a %v-byte chunk failed: %v",
				path,
				n,
				aerr,
				allocator = allocator,
			)
		}
		_, app_err := append(&loaded.ids, id)
		if app_err != .None {
			loaded_destroy(loaded)
			return errs.newf(
				.Resource_Limit,
				"fileload: %s: recording chunk %v failed: %v",
				path,
				len(loaded.ids),
				app_err,
				allocator = allocator,
			)
		}
	}

	// Verify the file did not change under us: re-stat the same
	// handle and require the captured id/size/mtime to still hold.
	fi2, ferr2 := os.fstat(f, allocator)
	if ferr2 != nil {
		loaded_destroy(loaded)
		return stat_error(path, ferr2, allocator)
	}
	defer os.file_info_delete(fi2, allocator)

	cap2, cerr2 := capture_from_stat(
		u64(fi2.device),
		u64(fi2.inode),
		fi2.size,
		fi2.modification_time,
		allocator,
	)
	if !errs.ok(cerr2) {
		loaded_destroy(loaded)
		return cerr2
	}
	if !fileid.stamp_equal(cap.stamp, cap2.stamp) {
		loaded_destroy(loaded)
		return errs.newf(
			.Conflict,
			"fileload: %s changed while it was being loaded (identity, size, or mtime no longer match the load-time stamp)",
			path,
			allocator = allocator,
		)
	}

	loaded.capture = cap
	return {}
}

// loaded_destroy releases everything `loaded` owns (the chunk store
// and the id list) and resets it to the zero state. Destroying a zero
// Loaded is safe and does nothing. Call exactly once, after every
// borrowed chunk view is done.
loaded_destroy :: proc(loaded: ^Loaded) {
	chunk.destroy(&loaded.store)
	delete(loaded.ids)
	loaded^ = Loaded{}
}
