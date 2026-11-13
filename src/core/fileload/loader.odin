// Loader: background chunked loading on one worker thread (M03.02,
// SPECS.md §4.2–§4.4, AGENTS.md §13).
//
// The caller (the single mutation owner — the UI thread) submits
// `load_file` requests; the worker opens, stats, reads, and interns
// off the caller's thread; completed loads come back through a
// bounded result queue for the caller to apply. This is the first
// consumer of the M01.05 queue and the M03.02 "on a worker"
// requirement.
//
// Revisioned results (SPECS.md §4.3): every request carries a
// caller-assigned `Request_ID` and every result echoes it (plus the
// worker thread id for diagnostics). The caller must validate the id
// before applying a result — results for cancelled or superseded
// requests are discarded, never silently applied. The remaining §4.3
// fields (buffer id, buffer generation, source revision) belong to
// the buffer registry, not to this package; they attach when the
// registry lands.
//
// Bounded (SPECS.md §4.4): both queues have fixed compile-time
// capacity (caller-owned storage inside the Loader). `loader_submit`
// applies backpressure (blocking) while the request queue is full;
// the worker applies backpressure while the result queue is full.
// A caller that never polls its results will stall the worker — the
// documented usage is submit + poll in the same loop.
//
// Cancellation: `loader_cancel` sets a sticky flag. Requests picked
// up while the flag is set complete with `.Cancelled`; an in-flight
// load aborts between chunks (the flag is passed to `load_file`).
// `loader_resume` clears the flag. Cancellation never stops the
// worker.
//
// Shutdown: `loader_close` (idempotent) rejects new requests; the
// worker drains the request queue (cancelled requests fast) and then
// closes the result queue. `loader_poll` is non-blocking (false while
// the worker is still running); `loader_is_done` reports when the
// worker has exited. `loader_destroy` closes, discards any unconsumed
// results (their chunk data lives on the loader arena), joins the
// worker, and releases the arena. Destroy waits for in-flight work:
// call `loader_cancel` first to abort a long load.
//
// Ownership:
//
//   - The loader owns one growing virtual arena (thread-safe —
//     internal mutex). Request copies, result structs, the loaded
//     chunk stores, id lists, and error messages all live on it.
//     `loaded_destroy` on a worker result is therefore a no-op
//     release (arena frees are no-ops); `loader_destroy` reclaims
//     everything with one `arena_free_all`. Consume every result
//     (build the rope, move the content) *before* `loader_destroy`.
//   - `Loader` contains queues (condition variables) and must not be
//     copied: pass by pointer, never by value. Initialize once,
//     destroy once.
package fileload

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"

import mem_virtual "core:mem/virtual"

import errs "../errs"
import queue "../queue"

// Request_ID identifies one load request. Values are caller-assigned
// (a per-buffer counter, a request serial, ...); 0 is a legal value.
Request_ID :: distinct u64

// REQUESTS_CAPACITY and RESULTS_CAPACITY are the fixed queue
// capacities (SPECS.md §4.4 — bounded by construction).
REQUESTS_CAPACITY :: 4
RESULTS_CAPACITY :: 4

// Load_Request is one queued load. `path` is an owned copy taken by
// loader_submit (loader arena); the caller may release theirs
// immediately. Requests are loader-owned; never construct or destroy
// one outside this package.
Load_Request :: struct {
	id:      Request_ID,
	path:    string,
	options: Load_Options,
}

// Load_Result is one completed load, owned by the loader arena.
// `loaded` is valid iff `errs.ok(err)`; `err` is owned (the caller
// may `errs.destroy` it — a no-op release against the arena — or
// leave it to `loader_destroy`).
Load_Result :: struct {
	id:         Request_ID, // echoes the request (§4.3 request_id)
	worker_tid: int, // the worker thread id that produced this result
	loaded:     Loaded,
	err:        errs.Error, // .Cancelled for cancelled requests
}

// Loader runs chunked loads on one background worker thread.
Loader :: struct {
	requests: queue.Queue(^Load_Request),
	results:  queue.Queue(^Load_Result),
	// Caller-owned queue storage (fixed capacity, zero allocation
	// after init).
	requests_buf: [REQUESTS_CAPACITY]^Load_Request,
	results_buf:  [RESULTS_CAPACITY]^Load_Result,
	cancel:       bool, // atomic; sticky until loader_resume
	done:         bool, // atomic; set by the worker just before exit (and by destroy)
	arena:        mem_virtual.Arena, // growing; owns all loader data
	thread:       ^thread.Thread,
	started:      bool,
}

// loader_init prepares a loader: the arena, the bounded queues, and
// the cancellation state. The worker is not running yet
// (loader_start). Initialize once; destroy once.
loader_init :: proc(l: ^Loader, allocator := context.allocator) -> errs.Error {
	if aerr := mem_virtual.arena_init_growing(&l.arena); aerr != .None {
		return errs.newf(
			.Resource_Limit,
			"fileload: cannot initialize the loader arena: %v",
			aerr,
			allocator = allocator,
		)
	}
	queue.init(&l.requests, l.requests_buf[:])
	queue.init(&l.results, l.results_buf[:])
	l.cancel = false
	l.done = false
	l.started = false
	return {}
}

// worker_proc is the worker loop: pop requests until the queue is
// closed, load (or cancel) each, push the result, then close the
// result queue and flag exit.
worker_proc :: proc(t: ^thread.Thread) {
	l := cast(^Loader)t.data
	arena := mem_virtual.arena_allocator(&l.arena)
	for {
		req, ok := queue.pop(&l.requests)
		if !ok {
			break
		}
		res := new(Load_Result, arena)
		res.id = req.id
		res.worker_tid = t.id
		if sync.atomic_load(&l.cancel) {
			res.err = errs.newf(
				.Cancelled,
				"fileload: request %v was cancelled",
				u64(req.id),
				allocator = arena,
			)
		} else {
			res.err = load_file(&res.loaded, req.path, req.options, arena, &l.cancel)
		}
		// Backpressure: a caller that never polls stalls the worker
		// here. destroy drains, so it can never deadlock against it.
		queue.push(&l.results, res)
	}
	sync.atomic_store(&l.done, true)
	queue.close(&l.results)
}

// loader_start spawns the worker thread. The thread runs with a
// context whose allocators are the loader arena, so every allocation
// the worker makes (its own, or `core:os` internal ones) lands on the
// arena. `allocator` backs the thread handle itself (thread.create
// allocates from context.allocator, which may be a panic allocator in
// the product — scope an explicit one instead).
loader_start :: proc(l: ^Loader, allocator := context.allocator) -> errs.Error {
	if l.started {
		return {}
	}
	ctx := runtime.default_context()
	ctx.allocator = mem_virtual.arena_allocator(&l.arena)
	ctx.temp_allocator = ctx.allocator

	prev := context.allocator
	context.allocator = allocator
	l.thread = thread.create(worker_proc)
	context.allocator = prev
	if l.thread == nil {
		return errs.newf(
			.Resource_Limit,
			"fileload: cannot create the loader worker thread",
			allocator = allocator,
		)
	}
	l.thread.data = l
	l.thread.init_context = ctx
	l.started = true
	thread.start(l.thread)
	return {}
}

// loader_submit queues a load request. Blocking (backpressure) while
// the request queue is full; `.Closed` after loader_close. The path
// is copied into loader-owned storage. The caller must validate the
// echoed id before applying the result.
loader_submit :: proc(
	l: ^Loader,
	id: Request_ID,
	path: string,
	options: Load_Options,
) -> queue.Push_Status {
	arena := mem_virtual.arena_allocator(&l.arena)
	req := new(Load_Request, arena)
	req.id = id
	req.path = strings.clone(path, arena)
	req.options = options
	// The arena is thread-safe (internal mutex), so the submitter and
	// the worker can allocate from it concurrently.
	return queue.push(&l.requests, req)
}

// loader_poll returns the oldest completed load without blocking.
// ok=false means "no result right now" — the worker may still be
// running with more results coming (check loader_is_done to know when
// the worker has exited and poll can never succeed again). The result
// is owned by the loader arena: consume it (and the loaded content)
// before loader_destroy.
loader_poll :: proc(l: ^Loader) -> (res: ^Load_Result, ok: bool) {
	res, ok = queue.try_pop(&l.results)
	return
}

// loader_is_done reports whether no further result can arrive: the
// worker has exited (and the result queue is drained) or the loader
// was destroyed. Once true, poll can never succeed again.
loader_is_done :: proc(l: ^Loader) -> bool {
	if sync.atomic_load(&l.done) {
		return true
	}
	return false
}

// loader_cancel sets the sticky cancellation flag: queued requests
// complete with `.Cancelled` and an in-flight load aborts between
// chunks. Idempotent; the worker keeps running.
loader_cancel :: proc(l: ^Loader) {
	sync.atomic_store(&l.cancel, true)
}

// loader_resume clears the cancellation flag so later requests load
// normally.
loader_resume :: proc(l: ^Loader) {
	sync.atomic_store(&l.cancel, false)
}

// loader_close rejects new requests (idempotent). Queued requests are
// still processed — cancelled ones fast — and every submitted request
// gets exactly one result before poll reports false.
loader_close :: proc(l: ^Loader) {
	queue.close(&l.requests)
}

// loader_destroy closes the loader, waits for the worker, discards
// any unconsumed results (releasing their stores — no-ops against the
// arena), joins the thread, and releases all loader-owned memory.
// Call once, after every kept result has been consumed; in-flight
// loads run to completion first (loader_cancel aborts them). Destroy
// never deadlocks against result backpressure: it drains the queue.
loader_destroy :: proc(l: ^Loader) {
	loader_close(l)
	if l.thread != nil {
		// The worker is (or was) running: drain with a blocking pop
		// (not poll: the worker may still be running and poll would
		// busy-spin). pop returns false once the worker has closed
		// the drained result queue.
		for {
			res, ok := queue.pop(&l.results)
			if !ok {
				break
			}
			loaded_destroy(&res.loaded)
		}
		thread.join(l.thread)
		thread.destroy(l.thread)
		l.thread = nil
	} else {
		// Never started: nothing was queued, and the result queue is
		// still open — close it so no later pop could block on it.
		queue.close(&l.results)
	}
	mem_virtual.arena_free_all(&l.arena)
	mem_virtual.arena_destroy(&l.arena)
	l.started = false
	// After destroy no result can ever arrive; report done so a
	// caller's poll loop terminates regardless of whether the worker
	// ever ran.
	sync.atomic_store(&l.done, true)
}
