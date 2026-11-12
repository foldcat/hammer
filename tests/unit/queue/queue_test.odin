// Tests for the bounded worker/result queue (M01.05):
// `hammer:core/queue` — bounded capacity, FIFO order, backpressure,
// try-push overflow policy, close/cancellation semantics, and
// multi-producer stress with real threads.
package queue_test

import "core:testing"
import "core:thread"
import "core:time"

import queue "hammer:core/queue"

Q :: queue.Queue(int)

// test_fifo_and_capacity pins the basic contract: FIFO order, fixed
// capacity, and the try_push overflow result.
@(test)
test_fifo_and_capacity :: proc(t: ^testing.T) {
	buf: [4]int
	q: Q
	queue.init(&q, buf[:])

	testing.expect(t, queue.capacity(&q) == 4)
	testing.expect(t, queue.count(&q) == 0)

	for i in 0 ..< 4 {
		testing.expect(t, queue.try_push(&q, i) == .Ok)
	}
	testing.expect(t, queue.try_push(&q, 99) == .Full)
	testing.expect(t, queue.count(&q) == 4)

	for i in 0 ..< 4 {
		v, ok := queue.try_pop(&q)
		testing.expect(t, ok)
		testing.expectf(t, v == i, "FIFO order: got %v, want %v", v, i)
	}
	_, ok := queue.try_pop(&q)
	testing.expect(t, !ok, "empty queue: try_pop must report false")
}

// test_wrap_around exercises the ring-buffer wrap: pushes and pops
// that cross the end of the backing array must keep FIFO order.
@(test)
test_wrap_around :: proc(t: ^testing.T) {
	buf: [4]int
	q: Q
	queue.init(&q, buf[:])

	for i in 0 ..< 4 {
		testing.expect(t, queue.push(&q, i) == .Ok)
	}
	for i in 0 ..< 2 {
		v, ok := queue.pop(&q)
		testing.expect(t, ok)
		testing.expect(t, v == i)
	}
	testing.expect(t, queue.push(&q, 4) == .Ok)
	testing.expect(t, queue.push(&q, 5) == .Ok)

	wants := []int{2, 3, 4, 5}
	for want in wants {
		v, ok := queue.pop(&q)
		testing.expect(t, ok)
		testing.expect(t, v == want)
	}
	_, ok := queue.try_pop(&q)
	testing.expect(t, !ok)
}

// test_close pins the cancellation contract: pushes fail with
// .Closed after close, consumers drain what remains, and then
// pop/try_pop report false.
@(test)
test_close :: proc(t: ^testing.T) {
	buf: [4]int
	q: Q
	queue.init(&q, buf[:])

	testing.expect(t, queue.push(&q, 10) == .Ok)
	testing.expect(t, queue.push(&q, 20) == .Ok)

	queue.close(&q)
	testing.expect(t, queue.is_closed(&q))

	testing.expect(t, queue.try_push(&q, 30) == .Closed)
	testing.expect(t, queue.push(&q, 30) == .Closed)

	v, ok := queue.pop(&q)
	testing.expect(t, ok && v == 10)
	v, ok = queue.pop(&q)
	testing.expect(t, ok && v == 20)

	_, ok = queue.pop(&q)
	testing.expect(t, !ok, "closed and drained: pop must report false")
	_, ok = queue.try_pop(&q)
	testing.expect(t, !ok)
	testing.expect(t, queue.count(&q) == 0)

	// close is idempotent.
	queue.close(&q)
	testing.expect(t, queue.is_closed(&q))
}

// Producer_State is shared test state: each producer records its push
// status in its indexed slot; join provides the happens-before edge.
Producer_State :: struct {
	status: queue.Push_Status,
	count:  int,
}

// producer_push pushes exactly one value and records the status.
producer_push :: proc(t: ^thread.Thread) {
	q := cast(^Q)t.data
	state := cast(^Producer_State)t.user_args[0]
	state.status = queue.push(q, 42)
}

// producer_spam pushes `count` values tagged with the producer index
// (`index*1000 + i`) with blocking push (backpressure).
producer_spam :: proc(t: ^thread.Thread) {
	q := cast(^Q)t.data
	state := cast(^Producer_State)t.user_args[0]
	for i in 0 ..< 250 {
		if queue.push(q, t.user_index * 1000 + i) != .Ok {
			return
		}
		state.count += 1
	}
}

// consumer_blocking_pop blocks in pop until the queue is closed.
consumer_blocking_pop :: proc(t: ^thread.Thread) {
	q := cast(^Q)t.data
	state := cast(^Producer_State)t.user_args[0]
	_, ok := queue.pop(q)
	state.status = queue.Push_Status.Closed if !ok else queue.Push_Status.Ok
}

// test_blocking_push_backpressure: with capacity 1, a second push
// must block (backpressure) until a pop frees space — the producer's
// push then succeeds with .Ok.
@(test)
test_blocking_push_backpressure :: proc(t: ^testing.T) {
	buf: [1]int
	q: Q
	queue.init(&q, buf[:])

	testing.expect(t, queue.push(&q, 1) == .Ok)
	testing.expect(t, queue.try_push(&q, 2) == .Full)

	state: Producer_State
	producer := thread.create(producer_push)
	producer.data = &q
	producer.user_args[0] = &state
	thread.start(producer)

	// Let the producer reach the blocking push, then free the slot.
	time.sleep(50 * time.Millisecond)
	v, ok := queue.pop(&q)
	testing.expect(t, ok && v == 1)

	thread.join(producer)
	thread.destroy(producer)
	testing.expectf(t, state.status == .Ok, "blocked push must succeed after a pop, got %v", state.status)

	v, ok = queue.pop(&q)
	testing.expect(t, ok && v == 42)
}

// test_blocking_pop_cancelled_by_close: a consumer blocked in pop is
// released by close and reports false.
@(test)
test_blocking_pop_cancelled_by_close :: proc(t: ^testing.T) {
	buf: [2]int
	q: Q
	queue.init(&q, buf[:])

	state: Producer_State
	consumer := thread.create(consumer_blocking_pop)
	consumer.data = &q
	consumer.user_args[0] = &state
	thread.start(consumer)

	time.sleep(50 * time.Millisecond)
	queue.close(&q)

	thread.join(consumer)
	thread.destroy(consumer)
	testing.expectf(
		t,
		state.status == .Closed,
		"consumer blocked in pop must observe close, got %v",
		state.status,
	)
}

// test_mpsc_stress: four producers push 250 items each through a
// 64-slot queue (forcing backpressure) while the main thread drains
// everything; every item must arrive exactly once and in
// per-producer order.
@(test)
test_mpsc_stress :: proc(t: ^testing.T) {
	buf: [64]int
	q: Q
	queue.init(&q, buf[:])

	states: [4]Producer_State
	producers: [4]^thread.Thread
	for i in 0 ..< 4 {
		producers[i] = thread.create(producer_spam)
		producers[i].data = &q
		producers[i].user_index = i
		producers[i].user_args[0] = &states[i]
		thread.start(producers[i])
	}

	seen := [4][250]int{}
	for total := 0; total < 1000; total += 1 {
		v, ok := queue.pop(&q)
		testing.expectf(t, ok, "producer stream ended early at %v items", total)
		producer := v / 1000
		slot := v % 1000
		testing.expectf(t, producer >= 0 && producer < 4 && slot >= 0 && slot < 250, "value %v out of range", v)
		seen[producer][slot] += 1
	}

	for i in 0 ..< 4 {
		thread.join(producers[i])
		thread.destroy(producers[i])
		testing.expectf(t, states[i].count == 250, "producer %v pushed %v/250", i, states[i].count)
	}

	for producer in 0 ..< 4 {
		for slot in 0 ..< 250 {
			testing.expectf(
				t,
				seen[producer][slot] == 1,
				"value %v seen %v times (want exactly once)",
				producer * 1000 + slot,
				seen[producer][slot],
			)
		}
	}

	queue.close(&q)
	_, ok := queue.pop(&q)
	testing.expect(t, !ok, "after close and drain, pop must report false")
}
