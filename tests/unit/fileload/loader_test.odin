// Tests for the M03.02 background loader (`hammer:core/fileload`):
// the single-worker queue wiring, the §4.3 request-id echo, the
// sticky cancellation contract, the close/drain shutdown sequence,
// and the no-deadlock destroy path under a long in-flight load.
package fileload_test

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import errs "hammer:core/errs"
import fileload "hammer:core/fileload"

// write_fixture creates a sandbox file with distinctive content and
// returns its path; the caller removes it.
write_fixture :: proc(t: ^testing.T, name: string, tag: u8, n: int) -> string {
	sandbox_init(t)
	path := fmt.tprintf("%s/%s", SANDBOX, name)
	content := make([]u8, n, context.allocator)
	defer delete(content)
	for i in 0 ..< n {
		content[i] = tag + u8(i % 17)
	}
	expect_ok(t, os.write_entire_file(path, content))
	return path
}

@(test)
test_loader_background_load :: proc(t: ^testing.T) {
	path := write_fixture(t, "loader-basic.txt", 0x41, 4096)
	defer os.remove_all(path)

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))
	defer fileload.loader_destroy(&l)

	testing.expect(t, fileload.loader_submit(&l, 42, path, {}) == .Ok)

	res, ok := wait_result(&l)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer if errs.ok(res.err) {
		fileload.loaded_destroy(&res.loaded)
	} else {
		errs.destroy(&res.err)
	}

	// The result echoes the request id (§4.3 request_id).
	testing.expect(t, res.id == 42)
	expect_ok(t, res.err)

	// The load really ran on the worker thread, not the caller's.
	testing.expectf(
		t,
		res.worker_tid != os.get_current_thread_id(),
		"result produced on the caller's thread (%d)",
		res.worker_tid,
	)

	// Content round-trips through the chunk store.
	got := concat_chunks(&res.loaded)
	defer delete(got)
	testing.expect(t, len(got) == 4096)
	testing.expect(t, got[0] == 0x41 && got[4095] == 0x41 + u8(4095 % 17))
	testing.expect(t, res.loaded.capture.stamp.size == 4096)
}

@(test)
test_loader_result_order :: proc(t: ^testing.T) {
	paths: [6]string
	defer for path in paths {
		os.remove_all(path)
	}
	for i in 0 ..< 6 {
		paths[i] = write_fixture(t, fmt.tprintf("loader-order-%v.txt", i), u8(0x61 + i), 1024)
	}

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))
	defer fileload.loader_destroy(&l)

	// Submit all six (capacity is 4: the worker keeps the request
	// queue draining, and the caller polls results between submits so
	// neither backpressure edge deadlocks). A single worker preserves
	// submission order, so the results must arrive as a FIFO.
	next := 100
	for i in 0 ..< 6 {
		testing.expect(t, fileload.loader_submit(&l, fileload.Request_ID(100 + i), paths[i], {}) == .Ok)
		if i % 2 == 1 {
			res, ok := wait_result(&l)
			testing.expect(t, ok)
			if !ok {
				return
			}
			testing.expectf(t, res.id == fileload.Request_ID(next), "FIFO order violated: want id %v, got %v", next, res.id)
			expect_ok(t, res.err)
			if errs.ok(res.err) {
				got := concat_chunks(&res.loaded)
				testing.expect(t, len(got) == 1024 && got[0] == u8(0x61 + (next - 100)))
				delete(got)
				fileload.loaded_destroy(&res.loaded)
			} else {
				errs.destroy(&res.err)
			}
			next += 1
		}
	}

	// The remaining results keep the order.
	for next < 106 {
		res, ok := wait_result(&l)
		testing.expect(t, ok)
		if !ok {
			return
		}
		testing.expectf(t, res.id == fileload.Request_ID(next), "FIFO order violated: want id %v, got %v", next, res.id)
		expect_ok(t, res.err)
		if errs.ok(res.err) {
			got := concat_chunks(&res.loaded)
			testing.expect(t, len(got) == 1024 && got[0] == u8(0x61 + (next - 100)))
			delete(got)
			fileload.loaded_destroy(&res.loaded)
		} else {
			errs.destroy(&res.err)
		}
		next += 1
	}
}

@(test)
test_loader_cancel_and_resume :: proc(t: ^testing.T) {
	path := write_fixture(t, "loader-cancel.txt", 0x51, 2048)
	defer os.remove_all(path)

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))
	defer fileload.loader_destroy(&l)

	// Cancellation is sticky: a request submitted while the flag is
	// set completes with .Cancelled, deterministically.
	fileload.loader_cancel(&l)
	testing.expect(t, fileload.loader_submit(&l, 1, path, {}) == .Ok)
	res, ok := wait_result(&l)
	testing.expect(t, ok && res.id == 1 && res.err.kind == .Cancelled)
	if ok {
		errs.destroy(&res.err)
	}

	// Resume restores normal loading.
	fileload.loader_resume(&l)
	testing.expect(t, fileload.loader_submit(&l, 2, path, {}) == .Ok)
	res2, ok2 := wait_result(&l)
	testing.expect(t, ok2 && res2.id == 2)
	if ok2 {
		expect_ok(t, res2.err)
		if errs.ok(res2.err) {
			fileload.loaded_destroy(&res2.loaded)
		} else {
			errs.destroy(&res2.err)
		}
	}
}

@(test)
test_loader_close_drains :: proc(t: ^testing.T) {
	paths: [3]string
	defer for path in paths {
		os.remove_all(path)
	}
	for i in 0 ..< 3 {
		paths[i] = write_fixture(t, fmt.tprintf("loader-close-%v.txt", i), 0x71, 512)
	}

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))
	defer fileload.loader_destroy(&l)

	for i in 0 ..< 3 {
		testing.expect(t, fileload.loader_submit(&l, fileload.Request_ID(200 + i), paths[i], {}) == .Ok)
	}
	fileload.loader_close(&l)

	// After close, new submits are rejected.
	testing.expect(t, fileload.loader_submit(&l, 999, paths[0], {}) == .Closed)

	// Every request submitted before close still gets one result.
	count := 0
	for {
		res, ok := wait_result(&l)
		if !ok {
			break
		}
		testing.expect(t, res.id >= 200 && res.id <= 202)
		expect_ok(t, res.err)
		if errs.ok(res.err) {
			fileload.loaded_destroy(&res.loaded)
		} else {
			errs.destroy(&res.err)
		}
		count += 1
	}
	testing.expect(t, count == 3)
	testing.expect(t, fileload.loader_is_done(&l))
}

@(test)
test_loader_error_result :: proc(t: ^testing.T) {
	sandbox_init(t)
	missing := SANDBOX + "/loader-missing.txt"
	os.remove_all(missing)

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))
	defer fileload.loader_destroy(&l)

	testing.expect(t, fileload.loader_submit(&l, 7, missing, {}) == .Ok)
	res, ok := wait_result(&l)
	testing.expect(t, ok && res.id == 7 && res.err.kind == .NotFound)
	if ok {
		errs.destroy(&res.err)
	}
}

@(test)
test_loader_cancel_midload :: proc(t: ^testing.T) {
	sandbox_init(t)
	path := SANDBOX + "/loader-slow.txt"
	// 64 MiB with a 1 KiB chunk size: thousands of read+intern steps,
	// comfortably longer than the 2 ms cancel delay, so the flag is
	// observed mid-load (a picked-up-after-cancel request would also
	// report .Cancelled — either way the result is .Cancelled).
	big := make([]u8, 64 * 1024 * 1024, context.allocator)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = u8(i % 251)
	}
	expect_ok(t, os.write_entire_file(path, big))
	defer os.remove_all(path)

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))

	testing.expect(t, fileload.loader_submit(&l, 1, path, {chunk_size = 1024}) == .Ok)
	time.sleep(2 * time.Millisecond)
	fileload.loader_cancel(&l)

	res, ok := wait_result(&l, 60 * time.Second)
	testing.expect(t, ok && res.id == 1 && res.err.kind == .Cancelled)
	if ok {
		errs.destroy(&res.err)
	}

	// Destroy under the aborted load must not deadlock: it closes,
	// drains, joins, and frees the arena.
	fileload.loader_destroy(&l)
}

@(test)
test_loader_destroy_discards_unconsumed :: proc(t: ^testing.T) {
	path := write_fixture(t, "loader-discard.txt", 0x81, 8192)
	defer os.remove_all(path)

	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	expect_ok(t, fileload.loader_start(&l, context.allocator))

	// Submit two loads and consume neither result: destroy must
	// discard them (releasing their stores — no-ops against the
	// loader arena) and still shut down cleanly.
	testing.expect(t, fileload.loader_submit(&l, 1, path, {}) == .Ok)
	testing.expect(t, fileload.loader_submit(&l, 2, path, {}) == .Ok)
	fileload.loader_destroy(&l)
	testing.expect(t, fileload.loader_is_done(&l))
}

// test_loader_destroy_without_start: destroying an initialized but
// never-started loader must not block (the drain used to block on the
// still-open result queue).
@(test)
test_loader_destroy_without_start :: proc(t: ^testing.T) {
	l: fileload.Loader
	expect_ok(t, fileload.loader_init(&l))
	fileload.loader_destroy(&l)
	testing.expect(t, fileload.loader_is_done(&l))
}
