# Concurrency and editor invariants

Referenced from `AGENTS.md`.

## 13. Concurrency rules

The editor core has one mutation owner.

Workers operate on immutable snapshots and return revisioned messages.

Do not mutate these from workers:

- Buffer roots.
- Selections.
- Window layout.
- Undo-tree active nodes.
- Dirty state.
- Project session state.

Background results must include:

- Stable target ID.
- Target generation.
- Source revision.
- Request ID.

Validate before applying.

Never silently apply stale results.

All asynchronous operations need:

- Cancellation.
- Bounded queues.
- Ownership rules.
- Shutdown behavior.
- Stale-result behavior.

Do not:

- Share a non-thread-safe allocator.
- Return pointers into reset worker scratch memory.
- Hold a lock while calling arbitrary external code.
- Block the UI waiting for a worker.
- Introduce threads for tasks that do not need them.

Use message passing where practical.

If locks are necessary, document lock ordering and ownership.

## 14. Editor invariants

These are non-negotiable unless the architecture is explicitly revised.

### 14.1 Transactions

All buffer edits go through transactions:

- Typing.
- Paste.
- Cut.
- Indentation.
- Edit commands.
- IPC writes.
- Filesystem writes.
- Command-output replacement.
- Recovery replay.
- Save-time formatting.

No subsystem edits rope internals behind the transaction engine.

### 14.2 Buffers versus views

Buffers own text/history/file state.

Views own:

- Selection.
- Scroll position.
- Geometry.
- View-specific interaction state.

Multiple views share buffer text, not selection or scroll state.

### 14.3 Coordinates

Keep separate:

- Byte offsets.
- Unicode scalar offsets.
- Grapheme positions.
- Logical lines/columns.
- Tree-sitter points.
- Pixels.
- Terminal cells.

Do not use one integer interchangeably for all of them.

Validate external ranges and UTF-8 boundaries according to the API contract.

### 14.4 Performance

Do not flatten the entire rope for:

- Painting a viewport.
- Moving a cursor.
- Reading a small range.
- Copying a small selection.
- Feeding Tree-sitter chunked input.
- Exporting a small IPC range.

Do not synchronously shape a gigantic line in full.

No whole-project scan on every finder keystroke.

No expensive Git query on every edit.

No expensive parse on the UI thread.

Measure before adding optimization complexity.
