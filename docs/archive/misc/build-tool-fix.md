## Build tool fix (2026-11-12 session)

`odin run make.odin -file -- run` no longer buffers the app's output:
`run_odin` captured stdout/stderr with `os.process_exec` (which asserts
the desc streams are nil and can only replay after the child exits), so
every runtime log line appeared only once the window was closed. The
`run` target now uses `os.process_start` with `stdout = os.stdout` /
`stderr = os.stderr` so logs stream live; build/test targets keep the
capture path. Verified live under Xvfb (wrapper stdout had `[INFO]`
lines while the app was still running) plus 57/57 unit tests and the
`build` capture path.

