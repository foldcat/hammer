# 6. Core data model

## 6.1 Separate buffers from views

This is one of the most important decisions.

### Buffer

Owns:

- Text.
- File identity.
- Encoding/newline metadata.
- Revision.
- Undo tree.
- Recovery state.
- Dirty state.
- Syntax state.
- Word index.
- External modification state.

### View/window

Owns:

- Buffer reference.
- Selection.
- Scroll position.
- Tag text.
- Geometry.
- Wrap mode.
- View-specific transient interaction state.

Two views of the same file must share text and undo history while keeping independent selections and scrolling.

## 6.2 Suggested conceptual types

```text
Editor
  projects
  buffers
  windows
  columns
  command_registry
  job_registry
  service_registry

Project
  id
  root_path
  file_index
  layout_state
  git_state
  session_state

Buffer
  id
  generation
  revision
  kind
  text_root
  saved_checkpoint
  file_metadata
  undo_tree
  recovery_state

Window
  id
  buffer_id
  tag_buffer
  selection
  viewport_anchor
  column_id
  layout_weight

Job
  id
  state
  command
  working_directory
  source_context
  output_target
  cancellation_state
```

## 6.3 Stable IDs

Use separate IDs for:

- Buffers.
- Windows.
- Projects.
- Jobs.
- Undo nodes.
- Transactions.
- IPC requests.

Do not use memory addresses as public identifiers.

Window IDs should remain stable for the lifetime of a window. Buffer IDs should remain stable for the lifetime of a buffer.

## 6.4 File identity

Track:

- Display path.
- Canonical path.
- Platform file identity where available.
- Symlink policy.
- Case sensitivity of the relevant filesystem.

Avoid opening the same file as two independent buffers merely because:

```text
foo.c
./foo.c
/path/project/foo.c
```

refer to the same file.

But do not assume all Windows volumes are case-insensitive or all Unix paths are case-sensitive.
