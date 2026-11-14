## M01.01 done (2026-11-12 session)

Lifecycle and error-reporting infrastructure (`docs/notes/m01-01-lifecycle.md`):

- `src/core/errs` (owned-message structured errors),
  `src/core/logging` (console + bounded file sink, mutex-serialized
  emission, panic reporter), `src/core/lifecycle` (phase state machine,
  idempotent quit, cancel hook for the M04 dirty review),
  `src/platform` (backend-free service interface table; the Sokol
  implementation lives in `src/main.odin`).
- Tests moved out of `src/` into `tests/unit/` (`hammer` collection):
  pinned Odin compiles `_test.odin` files into normal builds, which
  broke the `-no-crt` Windows cross-build (`core:testing` →
  `core:c/libc`). Trap recorded in `docs/notes/m00-09-decisions.md` §5.
- Validated headless: 17/17 unit tests (leak-checked); Linux
  debug/release Xvfb smokes (exit 0, clean tracking-allocator exit);
  Linux panic path (exit 132, `[PANIC ]` line in the log); console-only
  mode; Windows cross-build + Wine 11 smoke (lifecycle + logging under
  `-no-crt`); Wine panic path (AeDebug auto-exit configured in the
  task-owned WINEPREFIX). Real-desktop and real-Windows runs remain the
  recorded M01/D-02 follow-ups.

