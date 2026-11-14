## M01.05 done (2026-11-12 session)

Worker/result queues with bounded capacity (`docs/m01-05-queue.md`):

- New backend-free `src/core/queue`: `Queue(T)` ring buffer over
  caller-owned storage (capacity fixed at init, zero allocation
  after), `push` (blocking backpressure) / `try_push` (overflow
  policy: `.Full`/`.Closed`), `pop`/`try_pop`, `close` (idempotent
  cancellation: pushes fail, waiters wake, drain-then-false),
  `capacity`/`count`/`is_closed`. Mutex + two cond vars; `core:sync`
  only (libc-free on both platforms).
- SPECS.md §4.3 revisioned-result contract documented on the package,
  deliberately not encoded (no dead envelope types; M02/M09 own the
  envelope).
- `tests/unit/queue` added (6 tests: FIFO/capacity, wrap-around,
  close, backpressure thread test, close-wakeup thread test, 4×250
  MPSC stress). Validated: 51/51 unit tests leak-free, stress tests
  run 10× without a flake, throwaway consumer cross-built for
  windows_amd64 under `-no-crt` and run under Wine 11 (exit 0);
  product debug/release/run/windows/panic smokes unchanged.

