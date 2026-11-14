// Shared helpers for the fileload tests (M03.02): a task-owned test
// sandbox, error assertions, and the result-waiting loop.
package fileload_test

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import fileload "hammer:core/fileload"

// SANDBOX is the task-owned test sandbox (AGENTS.md §19: tests route
// state into a unique sandbox, never real user files). It is created
// under the system temp dir on first use — never a hardcoded
// /tmp/opencode path — so the tests run anywhere /tmp (or $TMPDIR) is
// writable, with or without an opencode-provided scratch area. Every
// test uses a distinct file name inside it so parallel test threads
// cannot collide.
SANDBOX: string

// sandbox_once ensures the shared sandbox path is computed exactly once
// across the parallel test threads.
@(private="file")
sandbox_once: sync.Once

// sandbox_buf backs SANDBOX so the path needs no allocator: a test's
// context.allocator does not outlive that test, so a globally shared
// path cannot be allocated from it.
@(private="file")
sandbox_buf: [512]u8

// sandbox_init creates the sandbox directory once.
sandbox_init :: proc(t: ^testing.T) {
	sync.once_do(&sandbox_once, proc() {
		dir, err := os.make_directory_temp("", "hammer-fileload-*", context.temp_allocator)
		if err != nil {
			return
		}
		n := copy(sandbox_buf[:], dir)
		if n < len(dir) {
			// The path did not fit in the fixed buffer; leave SANDBOX
			// empty so sandbox_init reports the failure instead of
			// running against a truncated, non-existent directory.
			return
		}
		SANDBOX = string(sandbox_buf[:n])
	})
	if SANDBOX == "" {
		testing.expect(t, false, "cannot create the fileload test sandbox")
	}
}

// sandbox_path joins a test-owned file name onto the shared sandbox.
// The result is scratch-allocated (context.temp_allocator), matching the
// existing convention: callers use it within the test scope, then remove
// the file with os.remove_all before the scratch arena is reset.
sandbox_path :: proc(name: string) -> string {
	return fmt.tprintf("%s/%s", SANDBOX, name)
}

// expect_ok asserts that `e` is the no-error sentinel (for
// `errs.Error`) or nil (for `os.Error`), printing a description on
// failure. Returns ok for short-circuiting.
expect_ok :: proc(t: ^testing.T, e: $T) -> bool {
	when T == errs.Error {
		if errs.ok(e) {
			return true
		}
		desc := errs.describe(e, context.allocator)
		testing.expectf(t, false, "unexpected error: %s", desc)
		delete(desc, context.allocator)
		local := e
		errs.destroy(&local)
		return false
	} else when T == os.Error {
		if e == nil {
			return true
		}
		testing.expectf(t, false, "unexpected os error: %v", e)
		return false
	} else {
		#panic("expect_ok: unsupported error type")
	}
}

// concat_chunks reproduces the loaded content from the chunk ids —
// the same contract the rope builder relies on. The result is
// allocated with context.allocator; the caller deletes it.
concat_chunks :: proc(loaded: ^fileload.Loaded) -> []u8 {
	total := 0
	for id in loaded.ids {
		total += len(chunk.data(&loaded.store, id))
	}
	out := make([]u8, total, context.allocator)
	pos := 0
	for id in loaded.ids {
		d := chunk.data(&loaded.store, id)
		copy(out[pos:], d)
		pos += len(d)
	}
	return out
}

// wait_result polls a loader until a result arrives, the worker has
// exited, or the deadline passes (bounded — never an unbounded poll).
// The caller decides how to consume the returned result.
wait_result :: proc(
	l: ^fileload.Loader,
	timeout := time.Duration(10 * time.Second),
) -> (
	^fileload.Load_Result,
	bool,
) {
	deadline := time.time_add(time.now(), timeout)
	for time.diff(time.now(), deadline) > 0 {
		res, ok := fileload.loader_poll(l)
		if ok {
			return res, true
		}
		if fileload.loader_is_done(l) {
			return nil, false
		}
		thread.yield()
	}
	return nil, false
}
