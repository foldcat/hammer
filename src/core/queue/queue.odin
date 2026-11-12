// Package queue: bounded, thread-safe worker/result queues (M01.05).
//
// This is the message-passing infrastructure every asynchronous
// subsystem will use (AGENTS.md §13, SPECS.md §4.4): workers push
// results, the UI thread (the single mutation owner) pops and applies
// them. Later milestones bind it to real consumers — M09 (process
// output), M12 (parser results), M19 (IPC subscriptions), M04
// (persistence jobs).
//
// Contracts:
//
// - **Bounded.** Capacity is fixed at `init` by the caller-owned
//   backing buffer; the queue never allocates after init and never
//   grows. Unlimited growth is impossible by construction (SPECS.md
//   §4.4).
// - **Thread-safe.** One mutex serializes all operations; condition
//   variables implement blocking waits. Producers and consumers may
//   be any number of threads (MPSC is the primary shape).
// - **Backpressure.** `push` blocks while the queue is full until
//   space appears or the queue is closed — the SPECS.md §4.4
//   "apply backpressure" behavior. Callers that prefer to coalesce,
//   drop, or disconnect use `try_push` and implement their own
//   overflow policy on `.Full`.
// - **Cancellation.** `close` makes pushes fail with `.Closed`,
//   unblocks every waiter, and lets consumers drain the remaining
//   items; `pop`/`try_pop` report `false` once the queue is empty
//   and closed. This is the queue-level cancellation mechanism; the
//   worker-side cancellation of in-flight work is each worker's own
//   contract (M09).
// - **Revisioned results (SPECS.md §4.3).** The queue transports
//   opaque values; the *producer* is responsible for attaching
//   revision metadata (buffer id, buffer generation, source
//   revision, request id) and the *consumer* validates before
//   applying. Never apply a stale result silently — the queue
//   deliberately does not know what staleness means.
//
// Backend-free: imports `core:sync` only (native SRWLock/futex
// primitives, no libc), so it builds under `-no-crt` as well as in
// the Sokol-free core.
package queue

import "core:sync"

// Push_Status reports the outcome of a push attempt.
Push_Status :: enum u8 {
	// Ok: the value was enqueued.
	Ok,
	// Full: the queue is at capacity (try_push only; push blocks
	// instead).
	Full,
	// Closed: the queue has been closed; the value was not enqueued.
	Closed,
}

// Queue is a bounded FIFO queue. It contains condition variables that
// must not be copied; treat a Queue as a fixed-location value — pass
// by pointer, never by value.
Queue :: struct($T: typeid) {
	mu:        sync.Mutex,
	not_full:  sync.Cond,
	not_empty: sync.Cond,
	// buf is caller-owned storage, borrowed for the queue's whole
	// lifetime; its length is the fixed capacity.
	buf:       []T,
	head:      int,
	count:     int,
	closed:    bool,
}

// init binds `q` to the caller-owned buffer `buf` (borrowed for the
// queue's lifetime; the caller destroys the storage) and resets it to
// empty and open. The queue then never allocates. `buf` must be
// non-empty. Zero-value `sync.Mutex`/`sync.Cond` are valid, so init
// only resets the queue's own fields.
init :: proc(q: ^Queue($T), buf: []T) {
	assert(len(buf) > 0, "queue: a bounded queue needs a non-empty buffer")
	q.buf = buf
	q.head = 0
	q.count = 0
	q.closed = false
}

// capacity returns the fixed queue capacity.
capacity :: proc(q: ^Queue($T)) -> int {
	return len(q.buf)
}

// count returns the number of currently queued items.
count :: proc(q: ^Queue($T)) -> int {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.count
}

// is_closed reports whether `close` has been called.
is_closed :: proc(q: ^Queue($T)) -> bool {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.closed
}

// push enqueues `value`, blocking while the queue is full
// (backpressure). Returns `.Closed` without enqueuing if the queue
// has been closed, `.Ok` otherwise.
push :: proc(q: ^Queue($T), value: T) -> Push_Status {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	for q.count == len(q.buf) && !q.closed {
		sync.cond_wait(&q.not_full, &q.mu)
	}
	if q.closed {
		return .Closed
	}
	q.buf[(q.head + q.count) % len(q.buf)] = value
	q.count += 1
	sync.cond_signal(&q.not_empty)
	return .Ok
}

// try_push enqueues `value` without blocking. Returns `.Full` at
// capacity and `.Closed` after close; the caller implements the
// overflow policy (coalesce/drop/disconnect — SPECS.md §4.4).
try_push :: proc(q: ^Queue($T), value: T) -> Push_Status {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	if q.closed {
		return .Closed
	}
	if q.count == len(q.buf) {
		return .Full
	}
	q.buf[(q.head + q.count) % len(q.buf)] = value
	q.count += 1
	sync.cond_signal(&q.not_empty)
	return .Ok
}

// pop removes and returns the oldest item, blocking while the queue
// is empty and open. Returns ok=false when the queue is closed and
// drained.
pop :: proc(q: ^Queue($T)) -> (value: T, ok: bool) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	for q.count == 0 && !q.closed {
		sync.cond_wait(&q.not_empty, &q.mu)
	}
	if q.count == 0 {
		return {}, false
	}
	value = q.buf[q.head]
	q.head = (q.head + 1) % len(q.buf)
	q.count -= 1
	sync.cond_signal(&q.not_full)
	return value, true
}

// try_pop removes and returns the oldest item without blocking.
// Returns ok=false when the queue is empty (open or closed).
try_pop :: proc(q: ^Queue($T)) -> (value: T, ok: bool) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	if q.count == 0 {
		return {}, false
	}
	value = q.buf[q.head]
	q.head = (q.head + 1) % len(q.buf)
	q.count -= 1
	sync.cond_signal(&q.not_full)
	return value, true
}

// close marks the queue closed: pushes fail with `.Closed`, all
// blocked waiters wake up, and consumers drain the remaining items
// before pop/try_pop report false. Close is idempotent.
close :: proc(q: ^Queue($T)) {
	sync.mutex_lock(&q.mu)
	q.closed = true
	sync.cond_broadcast(&q.not_empty)
	sync.cond_broadcast(&q.not_full)
	sync.mutex_unlock(&q.mu)
}
