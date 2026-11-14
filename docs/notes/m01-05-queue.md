# M01.05 — Worker/result queues with bounded capacity

**Status:** done (validated headless on Linux with real producer/
consumer threads; Windows cross-build + Wine 11 run of the queue
package under `-no-crt`). No consumer in the product yet — M09
(process output), M12 (parser results), M19 (IPC subscriptions), and
M04 (persistence) bind it.

This task delivers the bounded message-passing infrastructure
(SPECS.md §18 M01.05, §4.3/§4.4, AGENTS.md §13): a backend-free,
thread-safe, fixed-capacity queue that workers push into and the UI
thread (the single mutation owner) pops — with explicit backpressure
and close/cancellation semantics.

## What was built

| Piece | Responsibility |
| ----- | -------------- |
| `src/core/queue/queue.odin` | `Queue(T)` ring buffer over caller-owned storage; `init` (fixed capacity, zero allocation after init), `push` (blocking backpressure), `try_push` (overflow policy hook: `.Full`/`.Closed`), `pop`/`try_pop`, `close` (idempotent cancellation: pushes fail, waiters wake, drain-then-false), `capacity`/`count`/`is_closed`. One `sync.Mutex` + two `sync.Cond`s (not-full/not-empty). |
| `tests/unit/queue/queue_test.odin` | 6 tests: FIFO + capacity + `.Full`, ring wrap-around, close semantics (drain-then-false, idempotent), blocking-push backpressure (producer thread unblocked by a pop), blocking-pop cancelled by close, and a 4-producer × 250-item MPSC stress with per-producer ordering. Leak-checked; run 10× without a failure this session. |
| `make.odin` | `tests/unit/queue` added to the core test list. |

## Design contracts

### Bounded by construction (SPECS.md §4.4)

Capacity is fixed at `init` by the length of a caller-owned buffer;
the queue never allocates, never grows, and an unbounded queue is
unrepresentable. Overflow policy is the caller's choice, made
explicit:

- `push` blocks while full — the "apply backpressure" behavior.
- `try_push` returns `.Full` — for coalescing replaceable jobs,
  dropping, or disconnecting a lagging subscriber (§4.4).

### Cancellation

`close` is the queue-level cancellation mechanism: pushes return
`.Closed`, every blocked waiter is broadcast-woken, and consumers
drain remaining items before `pop`/`try_pop` report `false`. Worker-
side cancellation of in-flight work (beyond the queue) is each
worker's own contract — M09 owns that for processes.

### Revisioned results (SPECS.md §4.3) — documented, not encoded

The queue transports opaque values. The *producer* must attach
revision metadata (buffer id, buffer generation, source revision,
request id) and the *consumer* must validate before applying —
"never silently apply stale results." The queue deliberately does not
know what staleness means; the envelope types arrive with M02
(buffer ids) and M09 (jobs). No dead envelope types were created.

### Backend-freedom and `-no-crt`

Imports `core:sync` only, whose Windows backend is native Win32
(SRWLock, condition variables) and whose Unix backend is futex-based
— no libc. Verified: a throwaway consumer importing the queue
cross-compiled for `windows_amd64` with `-no-crt -no-thread-local`
and ran under Wine 11 (FIFO output, exit 0), exercising the Win32
synchronization path. The Sokol collection is not involved.

## Validation run (all commands executed this session)

```text
odin test tests/unit/queue -vet -collection:hammer=src  -> 6/6, leak-checked;
    repeated 10x (thread tests) — no flake observed
odin run make.odin -file -- test                        -> 51/51 (errs 6,
    logging 5, lifecycle 5, platform 1, config 14, coords 8, input 6,
    queue 6), leak-checked
Windows -no-crt check: throwaway consumer (/tmp/opencode/qcheck) built
    with -target:windows_amd64 -linker:lld -no-crt -no-thread-local
    -windows-sdk-root:build/windows-sdk  -> builds; runs under
    Wine 11: FIFO drain output + "ok", exit 0
debug/release/run smokes                                  -> exit 0
Windows product cross-build + Wine smoke                  -> exit 0
panic path (HAMMER_TEST_PANIC)                            -> exit 132
```

## Traps found (recorded for later tasks)

1. **Windows cross-linking needs `-linker:lld` explicitly**, plus the
   `-windows-sdk-root` and the import-lib list via
   `-extra-linker-flags:"/libpath:... kernel32.lib ..."` — odin's
   "Cannot link for Windows without LLD" error fires without
   `-linker:lld` even when `ODIN_LLD_PATH` is set (make.odin's
   windows target already passes all of these).
2. **`core:sync` is libc-free on both platforms** (native Win32 /
   futex), so queues and future worker code are safe for the
   `-no-crt` Windows build; `core:testing` is not (the M01.01 trap).
3. **Odin `for _, v in []int{...}` over a literal is a syntax error**
   in the pinned compiler; bind the literal to a variable first.
4. `sync.Mutex`/`sync.Cond` need no init (valid zero values); `Cond`
   is `#no_copy`, so a `Queue` must live at a fixed location and be
   passed by pointer.
5. **`.gitignore` had a bare `src` entry** (leftover protection for a
   root-level `src` build binary that make.odin never produces — all
   builds use `-out:build/...`). A bare pattern matches the *directory*
   `src/` too, so every new file under it was silently ignored:
   `src/core/coords`, `src/core/input`, and `src/core/queue` were
   never picked up by the M01.03/M01.04 commits (they exist on disk
   and are tracked by nothing). The entry is removed this session;
   the files show as untracked now and must land in the next commit.
   Check `git status` for missing source files after every session.

## Honest status

| Platform  | Status |
| --------- | ------ |
| Linux     | **tested**: unit tests with real threads (backpressure, close-wakeup, MPSC stress ×10), leak-free. No product consumer yet — M09/M12/M19/M04 will exercise it under load. |
| Windows   | **cross-build + Wine-run**: the queue itself compiles under `-no-crt` and drains correctly under Wine 11. Not exercised with real Windows threads/hardware (D-02). |

## Follow-ups (owners)

- M09.05 (process-output batching/backpressure): binds the queue to
  real workers — push strategy per output class, spill-to-disk,
  cancellation of in-flight work.
- M12 (parser workers): worker pool pushes revisioned parse results;
  the §4.3 envelope and stale validation land here.
- M19 (IPC subscribers): per-subscriber queues with the disconnect-on-
  lag policy.
- M04 (persistence): bounded persistence job queue.
- M01.06 (rectangles) does not consume this; the input `Event` stream
  stays direct until a cross-thread consumer exists (recorded in the
  M01.04 doc).
