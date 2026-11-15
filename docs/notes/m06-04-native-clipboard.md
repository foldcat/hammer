# M06.04 — Native clipboard services

**Status:** implemented for Linux/X11 and Windows. Linux/X11 native tests passed
under isolated Xvfb; Windows native tests passed under Wine/Xvfb with the
repository's no-CRT MinGW toolchain. Real Windows, real desktop sessions, and a
real X11 clipboard manager were not available for validation.

## Shared service contract

`src/platform/clipboard.odin` adds `Clipboard_Request`, `Clipboard_Result`,
`Clipboard_Ownership`, and `Clipboard_Service` to the existing platform boundary:

```text
start(request) -> immediate validation/error
poll(allocator) -> at most one owned result, bounded native work
cancel(request_id) -> reject later completion of an active read
```

Requests carry stable nonzero IDs, CLIPBOARD/PRIMARY, Read/Write, and a borrowed
write payload. Results carry the same identity, optional owned bytes, optional
structured error, ownership state, and the result allocator. `result_destroy`
releases both payload and error exactly once.

Write payloads are UTF-8 validated and cloned before native retention. Read
payloads are UTF validated before success. The default transfer ceiling is
64 MiB; native options can lower it. Completed-result queues and poll work are
bounded. No private editor clipboard or shell clipboard utility is used.

`platform.Services` now includes the clipboard proc table alongside window
metrics. Product paste target validation is the next task, not part of this one.

## Linux/X11

`src/platform/x11clipboard` uses direct Xlib integration on one UI thread:

- independent CLIPBOARD and optional PRIMARY ownership and payload lifetimes;
- `TARGETS`, `UTF8_STRING`, and `text/plain;charset=utf-8` serving;
- direct properties through 64 KiB and INCR above that size;
- at most four concurrent INCR transfers, each with an independent owned payload
  so a later copy cannot invalidate an in-flight transfer;
- one active read per service, bounded 64 KiB chunks, announcement/stream size
  checks, UTF-8 validation, deadlines, and cancellation;
- explicit `SelectionClear` results with `.Lost` and a conflict error;
- bounded `SAVE_TARGETS` handoff to an available `CLIPBOARD_MANAGER` during
  destroy, with a 250 ms deadline and continued service of manager requests;
- explicit refusal of unknown selections/targets and unsupported server byte
  order, plus an X error handler instead of Xlib's process-exit default.

No clipboard manager is installed in this environment. The handoff path was
therefore type-checked and regression-tested for the no-manager path, but actual
post-exit persistence was not runtime-validated. Wayland is not implemented or
claimed.

## Windows

`src/platform/winclipboard` uses native Win32 clipboard and global-memory APIs:

- `CF_UNICODETEXT` reads/writes with validated UTF-16/UTF-8 conversion, including
  surrogate pairs and rejection of unpaired surrogates;
- no fixed small read buffer: `GlobalSize` bounds the input and the exact UTF-8
  result is allocated with the result allocator;
- empty clipboard/empty text returns a successful empty result, while a
  nonempty clipboard without Unicode text returns `.Unsupported`;
- bounded `OpenClipboard` retries (five attempts with a 2 ms delay by default);
- system-owned clipboard handles are only locked/unlocked, never freed by Odin;
- a successful `SetClipboardData` transfers `HGLOBAL` ownership to Windows, while
  every earlier failure path calls `GlobalFree` exactly once;
- PRIMARY returns `.Unsupported` rather than masquerading as another selection.

A purpose-built no-CRT integration executable avoids dependencies on the Odin
test runner's CRT startup and matches the product's minimal Windows link model.

## Tests and validation

Common unit tests cover request validation and result ownership. Four X11 native
tests cover Unicode/empty/PRIMARY round-trips, two concurrent 256 KiB INCR reads,
ownership loss, no-owner errors, cancellation, PRIMARY policy, and budgets. The
Windows executable covers Unicode, empty text, 256 KiB, malformed UTF-16, and
PRIMARY policy.

```text
odin test tests/unit/platform -vet -collection:hammer=src
    -> 3/3 passed, allocator tracking clean
odin run make.odin -file -- clipboard-test
    -> 4/4 X11 native tests passed under isolated Xvfb
odin run make.odin -file -- clipboard-windows-test
    -> Windows/Wine Unicode, empty, 256 KiB, invalid UTF-16, PRIMARY checks passed
odin check src/platform/x11clipboard -no-entry-point -vet
odin check src/platform/winclipboard -no-entry-point -vet -target:windows_amd64
    -> both native type checks passed
odin run make.odin -file -- test
    -> all 282 core unit tests passed
odin run make.odin -file -- text-test
    -> all 26 native text tests passed; visual goldens matched
odin run make.odin -file -- build
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> Linux build and lifecycle smoke passed
odin run make.odin -file -- windows
xvfb-run -a env WINEDEBUG=-all HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine ./build/hammer.exe
    -> Windows cross-build and Wine lifecycle smoke passed
git diff --check
    -> no whitespace errors
```

`clipboard-test` and `clipboard-windows-test` in `make.odin` reproduce the native
validations with isolated displays and no user clipboard access.

## Limits and next task

- Real clipboard-manager persistence and interoperability with separate external
  desktop applications remain unvalidated; M06.08 owns interoperability coverage.
- Windows retry contention was not fault-injected. Only Wine, not real Windows,
  executed the native adapter.
- The 64 MiB ceiling was not exercised; tested large payloads were 256 KiB.
- M06.05 should capture paste target ID, generation, selection anchors, source
  revision, and request ID, rejecting late/stale results instead of pasting into
  the currently focused window.
