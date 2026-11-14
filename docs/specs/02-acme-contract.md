# 2. Preserve Acme’s contract before modernizing it

Before implementing features, create:

```text
docs/acme-compatibility.md
```

This should distinguish three things:

1. **Preserved behavior**
2. **Intentional modernization**
3. **Unsupported or deferred behavior**

Acme’s original design makes its three mouse actions and its filesystem interface central—not incidental. Rob Pike’s original paper should be the foundational reference. [1]

## 2.1 Behaviors to preserve

### Window and column model

- Multiple columns.
- Multiple windows within each column.
- Editable global, column, and window tags where applicable.
- Draggable window/column controls.
- Grow, shrink, and rearrangement behavior.
- Multiple views of one underlying buffer.
- Directory windows.
- Output/error windows.
- Tag commands reflecting window state.

### Mouse behavior

- Button 1: select.
- Button 2: execute.
- Button 3: look.
- Selection expansion rules.
- Supported original mouse chords.
- Scrolling behavior and scrollbar interaction.

Do not implement this using a collection of disconnected click callbacks. Use a real interaction state machine.

### Textual command behavior

Preserve the documented semantics of commands such as:

```text
New
Newcol
Del
Delcol
Get
Put
Putall
Undo
Redo
Look
Edit
Send
Dump
Load
```

Exact command coverage should come from the pinned Acme reference, not memory.

Modernization may add:

```text
Find
Files
History
Stop
Jobs
SaveAs
Discard
ConfigBuild
```

### Addressing and editing language

- File/address expressions.
- Character and line addresses.
- Regular-expression addresses.
- The documented Acme `Edit` language.
- Selection-oriented command execution.
- Selection-to-stdin and command-output-to-selection operations.

### External programmability

- Window creation.
- Reading and editing body/tag text.
- Addressed reads and writes.
- Selection access.
- Event observation.
- Event interception and reinjection where required for compatibility.
- Editor-level logs and lifecycle events.

## 2.2 Intentional behavior changes

Document these clearly:

- Commands run asynchronously.
- Unsaved work cannot be silently discarded.
- Explicit `Discard` is required instead of relying on an accidental repeated-close gesture.
- Native system clipboard integration is the default.
- Keyboard and touchpad alternatives are available.
- Syntax highlighting is optional and must not interfere with selection visibility.
- Large-file mode may reduce optional features, never editing correctness.
