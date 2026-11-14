package logging_test

// These tests exercise the logging subsystem's global state and must
// therefore run sequentially (they are serialized with test_gate; the
// Odin test runner executes tests on several threads in parallel). Each
// test fully shuts the subsystem down before returning.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import errs "hammer:core/errs"
import logging "hammer:core/logging"

// test_gate serializes the tests: every test below mutates the
// subsystem-global state. Tests in the other packages are pure and need
// no gate.
test_gate: sync.Mutex

THREADS :: 2
LINES_PER_THREAD :: 100

// thread_worker logs LINES_PER_THREAD lines tagged with the thread's
// user_index; used by test_concurrent_emits_do_not_interleave.
thread_worker :: proc(t: ^thread.Thread) {
	ctx := runtime.default_context()
	logging.install(&ctx)
	context = ctx
	for i in 0 ..< LINES_PER_THREAD {
		log.infof("worker-%d line %d", t.user_index, i)
	}
}

// sandbox_dir creates a unique, task-owned directory under the system
// temp dir (per AGENTS.md §19, test state never touches user state
// directories). It is created with a random suffix under the real temp
// dir — never a hardcoded /tmp/opencode path — so it works without an
// opencode-provided scratch area. The caller owns the returned
// directory and must remove it.
sandbox_dir :: proc(t: ^testing.T, name: string) -> string {
	pattern := fmt.tprintf("%s-*", name)
	dir, err := os.make_directory_temp("", pattern, context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "cannot create sandbox dir for %s: %v", name, err)
		return ""
	}
	return dir
}

@(test)
test_file_logging_roundtrip :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_gate)
	defer sync.mutex_unlock(&test_gate)

	dir := sandbox_dir(t, "hm-logging")
	if dir == "" {
		return
	}
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/hammer.log"})
	defer delete(path)

	init_err := logging.init(logging.Options{file_path = path, ident = "test"})
	defer logging.shutdown()
	if !errs.ok(init_err) {
		testing.expectf(t, false, "init failed: %v", errs.describe(init_err))
		return
	}

	// A second init must be refused while the subsystem is live.
	second := logging.init(logging.Options{file_path = path})
	testing.expect(t, second.kind == .Internal)
	errs.destroy(&second)

	ctx := runtime.default_context()
	logging.install(&ctx)
	context = ctx

	log.infof("hello %d", 42)
	log.warnf("careful %s", "now")
	log.errorf("boom %d-%s", 7, "x")

	logging.shutdown() // flush + close the file (the deferred shutdown is then a no-op)

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "cannot read log file: %v", rerr)
		return
	}
	text := string(data)
	wants := []string{"hello 42", "careful now", "boom 7-x", "[test]"}
	for want in wants {
		if !strings.contains(text, want) {
			testing.expectf(t, false, "log file missing %q; content:\n%s", want, text)
		}
	}
}

@(test)
test_level_filtering :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_gate)
	defer sync.mutex_unlock(&test_gate)

	dir := sandbox_dir(t, "hm-logging-levels")
	if dir == "" {
		return
	}
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/hammer.log"})
	defer delete(path)

	// File sink at .Warning: info lines must be filtered out.
	init_err := logging.init(logging.Options{file_path = path, lowest = .Warning})
	defer logging.shutdown()
	if !errs.ok(init_err) {
		testing.expectf(t, false, "init failed: %v", errs.describe(init_err))
		return
	}

	ctx := runtime.default_context()
	logging.install(&ctx)
	context = ctx

	log.infof("filtered %d", 1)
	log.warnf("kept %d", 2)
	logging.shutdown()

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "cannot read log file: %v", rerr)
		return
	}
	text := string(data)
	testing.expect(t, !strings.contains(text, "filtered 1"))
	testing.expect(t, strings.contains(text, "kept 2"))
}

@(test)
test_file_open_failure_leaves_console_only :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_gate)
	defer sync.mutex_unlock(&test_gate)

	dir := sandbox_dir(t, "hm-logging-fail")
	if dir == "" {
		return
	}
	defer os.remove_all(dir)
	// The parent directory does not exist: the open must fail.
	path := strings.concatenate({dir, "/missing/hammer.log"})
	defer delete(path)

	init_err := logging.init(logging.Options{file_path = path})
	defer logging.shutdown()
	testing.expectf(t, init_err.kind == .IO, "expected IO error, got %v", errs.describe(init_err))
	errs.destroy(&init_err)

	// Console logging must still be live.
	ctx := runtime.default_context()
	logging.install(&ctx)
	context = ctx
	log.errorf("still alive %d", 3) // exercised through _emit; no crash, no file
	logging.shutdown()
}

@(test)
test_truncation_of_oversized_log :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_gate)
	defer sync.mutex_unlock(&test_gate)

	dir := sandbox_dir(t, "hm-logging-trunc")
	if dir == "" {
		return
	}
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/hammer.log"})
	defer delete(path)

	// Seed an oversized file (scratch allocation; freed automatically).
	seed := make([]byte, logging.MAX_FILE_SIZE + 1024, context.temp_allocator)
	for &b in seed {
		b = 'x'
	}
	if err := os.write_entire_file(path, seed); err != nil {
		testing.expectf(t, false, "cannot seed log file: %v", err)
		return
	}

	init_err := logging.init(logging.Options{file_path = path})
	defer logging.shutdown()
	if !errs.ok(init_err) {
		testing.expectf(t, false, "init failed: %v", errs.describe(init_err))
		return
	}
	logging.shutdown()

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "cannot read log file: %v", rerr)
		return
	}
	testing.expectf(t, len(data) <= logging.MAX_FILE_SIZE, "log not truncated: %d bytes", len(data))
}

@(test)
test_concurrent_emits_do_not_interleave :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_gate)
	defer sync.mutex_unlock(&test_gate)

	dir := sandbox_dir(t, "hm-logging-threads")
	if dir == "" {
		return
	}
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/hammer.log"})
	defer delete(path)

	init_err := logging.init(logging.Options{file_path = path})
	defer logging.shutdown()
	if !errs.ok(init_err) {
		testing.expectf(t, false, "init failed: %v", errs.describe(init_err))
		return
	}

	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		th := thread.create(thread_worker)
		th.user_index = i
		thread.start(th)
		threads[i] = th
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	logging.shutdown()

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		testing.expectf(t, false, "cannot read log file: %v", rerr)
		return
	}
	text := string(data)
	lines := strings.count(text, "\n")
	testing.expectf(
		t,
		lines == THREADS * LINES_PER_THREAD,
		"expected %d lines, got %d",
		THREADS * LINES_PER_THREAD,
		lines,
	)
	// Every line must be intact (mutex-serialized emission).
	for i in 0 ..< THREADS {
		for j in 0 ..< LINES_PER_THREAD {
			want := fmt.tprintf("worker-%d line %d", i, j)
			if !strings.contains(text, want) {
				testing.expectf(t, false, "missing intact line %q", want)
				break
			}
		}
	}
}
