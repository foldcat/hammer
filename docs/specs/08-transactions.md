# 8. Transactions, selections, and undo

## 8.1 Everything edits through transactions

No subsystem may directly mutate text.

Examples:

- Typing.
- Paste.
- Cut.
- Indent.
- `Edit`.
- IPC writes.
- Command output replacement.
- Save-time formatting.
- Recovery restoration.

All become transactions.

```text
Transaction
  id
  source
  base_revision
  operations
  before_selection
  after_selection
  metadata_changes
  grouping_key
```

## 8.2 Edit operations

At minimum:

```text
Insert
Delete
Replace
```

A transaction may contain multiple non-overlapping edits.

Define whether ranges are expressed against the original transaction snapshot or sequential intermediate states. Prefer original-snapshot ranges for batch operations, with deterministic ordering.

## 8.3 Selection representation

Use:

```text
anchor
active_end
affinity
preferred_visual_column
```

Preserve selection direction.

For long-lived selections and asynchronous operations, use anchors that can be transformed through edits.

A plain integer offset is not enough for:

- Delayed clipboard results.
- Asynchronous pipes.
- IPC clients.
- Layout restoration.
- Multiple views.

## 8.4 Undo tree

Use a branching history:

```text
root
 └── edit A
      └── edit B
           ├── edit C
           └── edit D
```

If the user undoes B→A and makes a new edit, do not destroy the abandoned branch.

Each node contains:

- Parent ID.
- Child IDs.
- Transaction metadata.
- Timestamp.
- Before/after checkpoint information.
- Selection state.
- Optional descriptive label.

## 8.5 Undo grouping

Group:

- Consecutive typing.
- One paste.
- One indentation action.
- One `Edit` invocation.
- One asynchronous selection replacement.
- One save-formatting transaction.

Do not group unrelated edits just because they occurred within the same second.

## 8.6 Dirty state

A file is clean when its current text and relevant save metadata match the last successful saved checkpoint.

Use:

- Saved revision/checkpoint.
- Length/hash as useful accelerators.
- Correct equality verification where required.

Returning to the saved undo node should become clean.

Do not mark a file clean merely because a save was scheduled.
