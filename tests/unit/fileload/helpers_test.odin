// Shared helpers for the fileload tests (M03.02): a task-owned test
// sandbox, error assertions, and the result-waiting loop.
package fileload_test

import "core:os"
import "core:testing"
import "core:thread"
import "core:time"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import fileload "hammer:core/fileload"

// SANDBOX is the task-owned test sandbox (AGENTS.md §19: tests route
// state into a unique sandbox, never real user files). /tmp/opencode
// is the approved external scratch area; every test uses a distinct
// file name inside it so parallel test threads cannot collide.
SANDBOX :: "/tmp/opencode/fileload-tests"

// sandbox_init creates the sandbox directory once.
sandbox_init :: proc(t: ^testing.T) {
	if os.exists(SANDBOX) {
		return
	}
	if err := os.make_directory_all(SANDBOX); err != nil {
		testing.expectf(t, false, "cannot create the sandbox %s: %v", SANDBOX, err)
	}
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
