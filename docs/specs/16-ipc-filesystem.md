# 16. Replace 9P with modern IPC while keeping filesystem access

This deserves a deliberate design.

> A JSON file in a directory is not automatically a replacement for Acme’s live filesystem interface.

You need to define the semantics of reads, writes, events, addressing, revision conflicts, and command execution.

## 16.1 Two interfaces, one core

Recommended:

### A. Canonical local API

- Unix-domain socket on Unix.
- Named pipe on Windows.
- Versioned request/response protocol.
- Event subscriptions.
- No network listener by default.

### B. Filesystem interface

- Always-available ordinary-file state projection and request mailbox.
- Full live device-like semantics through FUSE/WinFsp when mounted.

Both call the same core action/transaction API.

Do not duplicate editing logic in the filesystem adapter.

## 16.2 Protocol choice

Use a versioned JSON-RPC-style protocol with explicit framing.

For example:

```text
length-prefixed UTF-8 JSON frames
```

Add chunked range reads/writes for large text.

Rules:

- Maximum frame size.
- Request IDs.
- Protocol version negotiation.
- Structured errors.
- Revision preconditions.
- Subscription sequence numbers.
- Cancellation where appropriate.

Do not send a one-gigabyte buffer as a single JSON string.

## 16.3 API methods

Suggested surface:

```text
editor.describe
editor.list_projects
editor.list_windows
editor.create_window
editor.request_quit

window.get_state
window.close
window.get_tag
window.set_tag
window.get_selection
window.set_selection
window.execute
window.look

buffer.get_metadata
buffer.read_range
buffer.apply_edits
buffer.save
buffer.undo
buffer.redo

job.start
job.list
job.cancel

events.subscribe
events.ack
events.resolve
```

## 16.4 Example revisioned edit

```json
{
  "id": 42,
  "method": "buffer.apply_edits",
  "params": {
    "buffer_id": "b-17",
    "expected_revision": 104,
    "edits": [
      {
        "start_byte": 120,
        "end_byte": 130,
        "text": "replacement"
      }
    ]
  }
}
```

Possible error:

```json
{
  "id": 42,
  "error": {
    "code": "REVISION_CONFLICT",
    "current_revision": 107
  }
}
```

Do not guess how to apply a stale replacement.

## 16.5 Event model

Each event has:

```text
sequence
event_id
kind
window_id
buffer_id
revision
origin
payload
```

Support:

- Observation.
- Optional interception.
- A defined ownership/lease model.
- Explicit reinjection/default handling.

An intercepted execute event must not run twice.

If an intercepting client disconnects:

- Release its lease.
- Resolve or cancel pending events according to documented policy.
- Never leave ordinary input permanently blocked.

## 16.6 Ordinary filesystem projection

Example:

```text
<runtime-root>/<instance>/
├── endpoint.json
├── status.json
├── index.json
├── windows/
│   └── 27/
│       ├── state.json
│       ├── tag.txt
│       ├── selection.json
│       └── snapshots/
│           └── 104/
│               ├── metadata.json
│               └── body.txt
├── requests/
├── replies/
└── events/
    ├── segment-000001.ndjson
    └── segment-000002.ndjson
```

### Important semantics

These are revisioned projections.

They are not silently writable live buffer files.

To request a mutation:

1. Write a request to a temporary file.
2. Atomically rename it into `requests/`.
3. Editor validates and executes.
4. A response appears in `replies/`.

Example request:

```json
{
  "request_id": "client-8-0042",
  "method": "window.execute",
  "params": {
    "window_id": 27,
    "text": "Put"
  }
}
```

### Why this exists

It provides driverless filesystem access on all supported platforms.

Shell scripts can inspect state and submit requests without requiring FUSE or WinFsp.

### Performance rule

Do not rewrite every body snapshot on every keystroke.

Use:

- Explicit revision labels.
- Lazy/on-request body materialization.
- Bounded event segments.
- Retention policy.
- Current-state metadata identifying what is exported.

## 16.7 Live mounted filesystem

For closer Acme semantics:

```text
/mount/acme-next/
├── index
├── log
├── new/
└── 27/
    ├── addr
    ├── body
    ├── tag
    ├── ctl
    ├── data
    ├── xdata
    ├── event
    ├── rdsel
    └── wrsel
```

Use the reference implementation to define which entries and semantics are required.

Mounted adapter responsibilities:

- Per-open state where required.
- Address cursor semantics.
- Snapshot consistency.
- Streaming body reads.
- Device-like writes.
- Event blocking/cancellation.
- Mapping kernel requests to asynchronous core calls.
- Safe unmount and editor shutdown.

### Windows realism

WinFsp installation is a deployment dependency.

The editor should still expose its driverless filesystem projection when WinFsp is absent.

However:

> The projection alone must not be advertised as complete live Acme filesystem compatibility.

If full mounted behavior is part of version 1, both FUSE and WinFsp adapters must pass their release gates.

## 16.8 Security

- Local user-only permissions.
- Restrictive Unix socket directory permissions.
- Restrictive named-pipe ACLs.
- No default remote listening.
- No control files in arbitrary project repositories.
- Request size limits.
- Connection/request limits.
- No automatic execution from output text.
- Capability or trust restrictions for automation where useful.

The automation interface can execute commands, so it is effectively a local code-execution interface.

Treat it accordingly.
