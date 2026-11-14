# 4. High-level architecture

```text
                         Native platform
                  window / input / DPI / IME
                              |
                              v
+-------------------------------------------------------------+
|                         UI thread                           |
|                                                             |
| Input normalization -> Action dispatcher -> Editor core     |
|                                      |                      |
|                              Transactions                   |
|                                      |                      |
|                        Buffers / views / projects           |
|                                      |                      |
|                         Layout + render snapshots           |
+---------------------------+---------------------------------+
                            |
          Immutable snapshots / revisioned messages
                            |
       +--------------------+------------------------+
       |                    |                        |
       v                    v                        v
  Worker pool          Process service          IPC service
  - parsing            - spawn                  - local RPC
  - indexing           - pipes                  - subscriptions
  - fuzzy search       - PTY / ConPTY            - authorization
  - file loading       - cancellation            - fs bridge
  - Git queries        - output decoding
  - persistence
       |                    |                        |
       +--------------------+------------------------+
                            |
                     Result message queue
                            |
                            v
                 UI-thread validation/apply
```

## 4.1 Single mutation owner

The editor core has **one mutation owner**.

Initially, make that the UI thread.

Only this owner may mutate:

- Buffer roots.
- Selections.
- Window layout.
- Undo-tree active nodes.
- Dirty state.
- Job attachment state.
- Project session state.

Workers operate on immutable snapshots and return results.

This avoids:

- Renderer/text-engine races.
- Undo corruption.
- Stale parse results overwriting current state.
- IPC handlers editing buffers while input is being processed.
- Complex lock ordering.

## 4.2 Headless core

The editor core must not import Sokol.

It should be possible to run:

```text
acme-core-tests
acme-core-benchmarks
acme --headless-test-session ...
```

without creating a window.

This is essential for agent-driven development.

## 4.3 Revisioned background results

Every background result carries enough information to validate it:

```text
buffer_id
buffer_generation
source_revision
request_id
result_kind
```

Apply only if:

- The buffer still exists.
- The generation matches.
- The result remains valid for the current revision.

If stale:

- Discard.
- Transform if the operation supports it.
- Or schedule a replacement computation.

Never silently apply stale results.

## 4.4 Bounded queues

All queues must be bounded:

- Process output.
- Parse requests.
- IPC requests.
- Event subscribers.
- Filesystem export work.
- Persistence jobs.

Define overflow behavior:

- Coalesce replaceable jobs.
- Apply backpressure.
- Spill process output to disk.
- Disconnect a lagging subscriber with an explicit gap/error.

Never allow unlimited output from a child process to consume all memory.
