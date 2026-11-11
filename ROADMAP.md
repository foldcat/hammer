# Project blueprint: a modern Acme in Odin + Sokol

The central idea should be:

> **Keep Acme’s interaction model, programmable text interface, columns, tags, and mouse workflow—but rebuild the implementation around a modern text engine, native platform integration, asynchronous jobs, and a versioned local API with filesystem access.**

Do **not** build a conventional IDE and apply Acme colors to it. The editor should still feel like Acme:

- Text is both content and interface.
- Commands are editable text.
- Selecting, executing, and looking up text are fundamental actions.
- Multiple windows can show the same buffer.
- External programs can create and manipulate editor windows.
- The filesystem interface is a first-class capability, not an afterthought.

At the same time, “original behavior” should not mean preserving clipboard bugs, poor font support, synchronous command execution, or unsafe data-loss behavior.

This plan is designed to become a repository’s architecture document, roadmap, and coding-agent operating procedure.

---

# 1. Product definition

~~Use a temporary project name such as **Acme Next** until naming and trademark questions are settled.~~ Let's call it hammer (`hm`), because when all you have is a hammer, everything can become nails...

## 1.1 Required experience

The editor should support:

| Area          | Required behavior                                                                 |
| ------------- | --------------------------------------------------------------------------------- |
| Interaction   | Acme selection, execution, lookup, mouse chording, editable tags                  |
| Touchpads     | Modifier-assisted equivalents for middle/right mouse actions                      |
| Keyboard      | Copy, paste, cut, undo, redo, selection movement, indentation                     |
| Text engine   | Rope-backed editing, efficient large-file access, multiple views                  |
| Rendering     | Unicode shaping, font fallback, configurable fonts and colors                     |
| Platforms     | Windows and Linux/Unix, with explicit backend support                             |
| Clipboard     | Real native system clipboard, not a private editor clipboard pretending to be one |
| Commands      | Asynchronous execution, cancellation, output windows, selection pipes             |
| Console       | Unicode output, ANSI styles, progress-line handling, optional PTY terminals       |
| Parsing       | Incremental Tree-sitter highlighting                                              |
| Completion    | Lightweight buffer-word completion                                                |
| Safety        | Safe save, shutdown protection, swap/recovery files                               |
| History       | Persistent branching undo history with an interactive tree                        |
| Projects      | Persistent layout, fuzzy finder, lightweight Git indicators                       |
| Configuration | Trusted Odin configuration compiled into the application                          |
| Automation    | Modern local IPC plus filesystem-visible state and control                        |
| Compatibility | A documented Acme behavior matrix and executable compatibility tests              |

## 1.2 Platform promise

Avoid saying “supports Unix” without specifying what that means.

Recommended release tiers:

### Tier 1

- Linux on X11. Prioritize X11 over Wayland. Prioritize Linux over Windows.
- Windows 10/11, subject to the minimum supported versions of dependencies.
- Linux on Wayland, with the chosen Sokol/native integration actually tested.

### Tier 2

- Other POSIX systems, such as FreeBSD.
- macOS if desired.

The core should be portable, but a POSIX abstraction does not automatically provide working fonts, clipboard, DPI, IME, or filesystem mounting on every Unix-like system.

## 1.3 Explicit non-goals for version 1

These keep the project manageable:

- No built-in LSP requirement.
- No extension marketplace.
- No embedded browser.
- No collaborative editing.
- No remote network server enabled by default.
- No full Git client.
- No mandatory terminal emulator in every command window.
- No runtime compilation of untrusted project configuration.
- No promise that existing 9P clients work unchanged.
- No AI integration.

A later compatibility adapter can support old clients, but the main architecture should not depend on 9P.

---

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

---

# 3. Recommended technology stack

## 3.1 Core

**Odin**

Use Odin for:

- Editor state.
- Text engine.
- Transactions.
- Layout.
- Input routing.
- Job orchestration.
- Project services.
- IPC dispatch.
- Persistence.
- Tests and benchmarks.

## 3.2 Application and rendering

**Sokol**

Use:

- `sokol_app` for the application shell where supported.
- `sokol_gfx` for GPU rendering.
- `sokol_glue` for backend integration where appropriate.
- Sokol shader tooling for portable shader generation.

Pin exact versions of:

- Odin.
- Sokol C headers.
- Odin Sokol bindings.
- Shader compiler tooling.

Do not assume every platform feature is available in the selected Sokol revision. Clipboard, IME, native Wayland support, per-monitor DPI, and idle-loop behavior require an early platform spike.

### Important boundary

Sokol is not the editor’s:

- Text engine.
- Shaping engine.
- Terminal emulator.
- Filesystem service.
- Command executor.

It is the application/rendering foundation.

## 3.3 Text rendering

Recommended:

- **FreeType** for font loading and glyph rasterization.
- **HarfBuzz** for shaping.
- A pinned Unicode implementation for:
  - Grapheme boundaries.
  - Word boundaries.
  - Bidirectional layout.
  - Character properties.

Choose one complete Unicode strategy early:

- ICU, or
- Smaller Unicode components plus a dedicated bidi implementation.

Do not assume HarfBuzz alone implements cursor movement, Unicode segmentation, or full paragraph bidi handling.

Existing Odin bindings for FreeType and HarfBuzz are available, but they should be audited and pinned rather than copied blindly. [2]

## 3.4 Syntax highlighting

**Tree-sitter**

Use:

- Incremental parsing.
- Highlight queries.
- Optional injections after basic highlighting works.

There are existing Odin Tree-sitter bindings that can reduce initial integration work. Pin the runtime, binding, grammar, scanner, and query versions together. [3]

## 3.5 Other dependencies

Recommended initial choices:

| Capability                       | Approach                                                          |
| -------------------------------- | ----------------------------------------------------------------- |
| Font discovery on Windows        | DirectWrite/system font APIs                                      |
| Font discovery on Linux          | Fontconfig                                                        |
| Git status/diff                  | `git` subprocesses first                                          |
| EditorConfig                     | Official library or a thoroughly tested compatible implementation |
| Local IPC on Unix                | Unix-domain sockets                                               |
| Local IPC on Windows             | Named pipes                                                       |
| Filesystem mount on Unix         | FUSE adapter                                                      |
| Filesystem mount on Windows      | WinFsp adapter                                                    |
| Interactive processes on Unix    | PTY                                                               |
| Interactive processes on Windows | ConPTY where supported                                            |

Keep dependencies behind narrow interfaces.

Do not write a font shaper, terminal emulator, Unicode implementation, and Git implementation just to keep the dependency list short.

---

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

---

# 5. Repository structure

A suggested structure:

```text
/
├── AGENTS.md
├── README.md
├── ROADMAP.md
├── NEXT.md
├── CHANGELOG.md
├── docs/
│   ├── architecture.md
│   ├── acme-compatibility.md
│   ├── text-model.md
│   ├── transactions.md
│   ├── platform-matrix.md
│   ├── ipc-protocol.md
│   ├── filesystem-api.md
│   ├── persistence-formats.md
│   ├── performance-budget.md
│   ├── test-plan.md
│   └── adr/
├── src/
│   ├── app/
│   ├── core/
│   ├── text/
│   ├── actions/
│   ├── commands/
│   ├── layout/
│   ├── render/
│   ├── fonts/
│   ├── unicode/
│   ├── platform/
│   │   ├── windows/
│   │   ├── linux/
│   │   └── posix/
│   ├── clipboard/
│   ├── jobs/
│   ├── console/
│   ├── terminal/
│   ├── syntax/
│   ├── completion/
│   ├── editorconfig/
│   ├── history/
│   ├── recovery/
│   ├── projects/
│   ├── fuzzy/
│   ├── git/
│   ├── ipc/
│   └── fs_bridge/
├── config/
│   ├── schema.odin
│   ├── defaults.odin
│   └── user.example.odin
├── tools/
│   ├── build/
│   ├── acmectl/
│   ├── fs_adapter/
│   └── dependency_setup/
├── tests/
│   ├── unit/
│   ├── property/
│   ├── integration/
│   ├── compatibility/
│   ├── platform/
│   ├── crash/
│   ├── fixtures/
│   └── golden/
├── bench/
├── assets/
├── third_party/
└── build/
```

Avoid creating one enormous `editor.odin`.

However, also avoid premature abstraction: interfaces should exist because a real boundary needs them, not because every function needs an interface.

---

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

---

# 7. Text engine: a persistent piece-rope

Use a **persistent, copy-on-write B-tree rope with immutable backing chunks**.

A piece-rope combines:

- Rope indexing and balancing.
- Immutable original/add storage.
- Cheap snapshots.
- Efficient undo-root retention.

## 7.1 Storage layers

```text
ByteStore
  immutable chunks / private backing snapshots

Piece
  store_id
  byte_start
  byte_length

Leaf
  small collection of pieces
  local metrics

Internal node
  children
  cumulative metrics

RopeRoot
  root node
  revision
```

## 7.2 Metrics

Maintain the metrics needed for:

- Byte indexing.
- UTF-8 scalar indexing.
- Line indexing.
- Tree-sitter byte/row conversion.

Possible cached metrics:

```text
byte_count
scalar_count
line_break_count
LF_count
boundary_summary
```

Boundary summaries must account for things such as CRLF spanning adjacent pieces.

Do not naively cache grapheme counts as though every boundary is independent. Unicode grapheme rules require context.

## 7.3 Coordinate systems

Explicitly distinguish:

1. **Internal UTF-8 byte offsets**
2. **Unicode scalar offsets**
3. **Grapheme cursor positions**
4. **Logical line/column positions**
5. **Tree-sitter byte points**
6. **Pixel positions**
7. **Terminal cell positions**

They are not interchangeable.

Recommended rule:

> The transaction engine uses internal byte ranges. UI movement uses grapheme boundaries. Acme-compatible addresses use their documented character semantics.

Every conversion goes through the text module.

## 7.4 Encoding and newline policy

Define this before writing save code.

Recommended:

- UTF-8 is the primary internal text encoding.
- Preserve LF and CRLF rather than silently normalizing on open.
- Supported non-UTF-8 encodings are decoded through a file codec layer.
- Retain the original encoding/BOM policy in file metadata.
- Unsupported encodings open read-only until the user explicitly chooses conversion.
- Invalid UTF-8 must never be silently replaced and then saved destructively.

For invalid bytes:

- Preserve the bytes.
- Render a clear replacement/escaped representation.
- Use explicit offset mapping.
- Disable or degrade parsing safely if necessary.
- Require deliberate conversion for lossy encoding changes.

## 7.5 Large-file behavior

Ropes do not make initial file loading or line indexing free.

Design for:

- Chunked background loading.
- A visible loading/indexing state.
- Early viewport preview when practical.
- Full editing only when the required invariants are established.
- Background line/index construction.
- Configurable large-file mode.

For very large files:

- Reduce or disable full-buffer syntax parsing.
- Limit completion indexing.
- Avoid whole-buffer fuzzy content scans by default.
- Render only visible content.
- Keep output and history budgets bounded.

### Important memory-mapping rule

Do not casually memory-map the original writable file and assume it is immutable.

External truncation can invalidate mappings on some platforms.

Prefer:

- Immutable in-memory chunks for ordinary files.
- A private, stable backing snapshot for very large files.
- Reflink/copy-to-private-backing where supported.
- Mapping that private snapshot rather than a user file that another process can truncate.

## 7.6 Complexity targets

Aim for:

- Seek: `O(log n)`.
- Insert/delete: `O(log n + changed content)`.
- Snapshot: cheap root/reference capture.
- Visible-range read: proportional to visible content and touched leaves.
- Line lookup: `O(log n)` after metrics are available.

Do not flatten the entire rope for:

- Rendering.
- Clipboard extraction of a small range.
- Parsing input callbacks.
- Small saves to a temporary stream.
- IPC range reads.

## 7.7 Mandatory property tests

Compare randomized rope operations against a simple reference byte/text model.

Test:

- Insertions.
- Deletions.
- Replacements.
- Splits and concatenation.
- Undo/redo.
- Scalar conversions.
- Line conversions.
- CRLF across piece boundaries.
- Emoji sequences.
- Combining characters.
- Invalid UTF-8.
- Empty files.
- Huge individual lines.

---

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

---

# 9. Rendering, Unicode, fonts, and DPI

## 9.1 Rendering architecture

Use custom editor rendering on Sokol.

Recommended layers:

```text
Background
Git gutter/change marks
Syntax styles
Search matches
Selection
Text glyphs
Caret
Tag controls
Transient overlays
```

Keep layout state retained, while allowing the drawing code to have an immediate-mode feel.

Do not use a generic multiline text widget as the final editor implementation.

## 9.2 Shape visible text

Pipeline:

```text
Rope range
 -> line segmentation
 -> script/bidi runs
 -> font fallback
 -> HarfBuzz shaping
 -> glyph lookup/rasterization
 -> positioned glyph draw commands
```

Use one shaped representation for:

- Rendering.
- Hit testing.
- Selection geometry.
- Cursor positioning.

Otherwise clicking and visual text will disagree.

## 9.3 Font handling

Support:

- Family-name lookup.
- Explicit font file paths.
- Ordered fallback families.
- Separate body/tag/console font roles if desired.
- Font size in points.
- Configurable line height.
- Optional ligatures.
- Missing-glyph diagnostics.

Fallback must work by appropriate shaping cluster/run boundaries, not by swapping individual code points indiscriminately.

## 9.4 Glyph cache

Cache keys should include:

```text
font identity
face index
variation settings
glyph ID
pixel size
render mode
```

Use bounded atlas pages with eviction.

Do not let every zoom level or monitor transition permanently add another complete font atlas.

## 9.5 Unicode behavior

Required:

- Combining marks.
- Extended grapheme sequences.
- CJK.
- Emoji sequences.
- Correct selection boundaries.
- Correct shaping for scripts that require it.
- Bidi policy documented and tested.
- IME preedit and commit handling.

For source code, consider visible indicators for:

- Bidi control characters.
- Nonprinting characters.
- Suspicious whitespace.

These should not alter the underlying file.

## 9.6 DPI model

Store layout measurements in logical units.

Convert to physical pixels using the current window/monitor scale.

For a point-based font size:

```text
logical pixels ≈ points × 96 / 72
physical pixels = logical pixels × scale
```

The exact platform integration must account for whether event coordinates and framebuffer sizes are already scaled.

Never apply DPI twice.

On DPI changes:

1. Update scale.
2. Recompute font pixel sizes.
3. Invalidate relevant glyph/layout caches.
4. Preserve logical layout proportions.
5. Redraw.

Test:

- 100%, 125%, 150%, 200%.
- Moving between mixed-DPI monitors.
- Resizing.
- Touchpad scrolling.
- Hit-testing at fractional scale.

## 9.7 Huge lines

A single ten-megabyte line must not freeze rendering.

Use:

- Bounded visible-range processing.
- Chunked/segmented measurement.
- Safe shaping boundaries.
- Incremental width measurement.
- Explicit large-line fallback behavior.

Never shape an entire enormous line synchronously merely to paint its visible beginning.

---

# 10. Input and clipboard

## 10.1 Unified action dispatch

All input maps to semantic actions:

```text
Select
ExtendSelection
ExecuteText
LookText
Copy
Cut
Paste
Undo
Redo
Indent
Outdent
MoveCursor
OpenFinder
CloseWindow
RequestQuit
```

Mouse, keyboard, touchpad modifiers, IPC, and textual commands should share the same action layer where semantics match.

## 10.2 Mouse state machine

Track:

- Pressed buttons.
- Initial target.
- Drag threshold.
- Selection origin.
- Chord state.
- Modifier state at gesture start.
- Gesture cancellation.
- Lost focus/capture.

Test original Acme chords against the reference behavior.

Do not automatically enable X11 middle-click paste over Acme’s middle-button execution behavior.

## 10.3 Touchpad defaults

Suggested configurable defaults:

| Gesture                   | Action           |
| ------------------------- | ---------------- |
| Plain primary click/drag  | Select           |
| Ctrl + primary click/drag | Execute          |
| Alt + primary click/drag  | Look             |
| Shift + primary click     | Extend selection |

Potential conflicts:

- Alt-drag may be intercepted by a Linux window manager.
- Platform-specific shortcuts can interfere.
- Modifier-assisted clicks must not accidentally begin a text drag.

Therefore provide alternate bindings, such as:

```text
Ctrl+Enter  Execute selection/token
Alt+Enter   Look selection/token
```

Use keydown actions for shortcuts and text-input events for inserted text.

## 10.4 Modern keyboard defaults

| Binding            | Action                      |
| ------------------ | --------------------------- |
| Ctrl+C             | Copy                        |
| Ctrl+X             | Cut                         |
| Ctrl+V             | Paste                       |
| Ctrl+Z             | Undo                        |
| Ctrl+Shift+Z       | Redo                        |
| Ctrl+Y             | Optional redo alias         |
| Ctrl+A             | Select all                  |
| Ctrl+S             | Put/save                    |
| Ctrl+Shift+S       | Save as                     |
| Ctrl+F             | Find                        |
| Ctrl+P             | Fuzzy file finder           |
| Ctrl+W             | Close current window safely |
| Ctrl+Q             | Request quit safely         |
| Shift+arrows       | Extend selection            |
| Ctrl+arrows        | Word movement               |
| Ctrl+Shift+arrows  | Word selection              |
| Home/End           | Line movement               |
| Shift+Home/End     | Extend to line boundary     |
| Tab with selection | Indent selected lines       |
| Shift+Tab          | Outdent                     |

Handle AltGr correctly. A Ctrl+Alt key combination used to produce text must not trigger an unrelated command.

## 10.5 Indentation behavior

When a multiline selection is active:

- `Tab` indents every covered line.
- `Shift+Tab` removes one indentation unit.
- The operation is one undo transaction.
- Preserve selection direction.
- Adjust selection anchors.
- Respect EditorConfig indentation settings.

Define the boundary rule:

> If a selection ends exactly at the start of a line, that final line is not included unless the selection actually covers its content.

When no selection exists:

- Insert a tab or indentation spaces according to effective settings.

## 10.6 Clipboard service

Use a platform service:

```text
ClipboardRequest
ClipboardResult
ClipboardOwnership
ClipboardError
```

Clipboard operations may be asynchronous even if a particular OS API is synchronous.

### Windows

Use native Unicode clipboard handling.

Requirements:

- UTF-16 conversion.
- Correct ownership/lifetime rules.
- Bounded retry if another application temporarily holds the clipboard.
- Correct empty clipboard behavior.
- No fixed small buffer limit.

### X11

Handle:

- `CLIPBOARD`.
- Optional `PRIMARY`, separately configurable.
- Ownership.
- UTF-8 targets.
- Large transfers, including incremental transfer behavior.
- Clipboard-manager persistence where available.

### Wayland

Use the supported native clipboard mechanism.

Requirements:

- Correct seat/focus/serial integration where required.
- Asynchronous transfer.
- Tested behavior on supported compositors.
- No shelling out to `wl-copy` as the primary implementation.

### Contract

Copy should publish the current selection to the real system clipboard.

Paste should retrieve the current system clipboard, not an old internal copy.

Keep a private fallback only if:

- It is explicitly identified as a fallback.
- A visible error explains the native failure.
- The application does not pretend the fallback is the system clipboard.

### Delayed paste safety

A paste request captures:

- Target buffer.
- Target selection anchors.
- Target generation.
- Request ID.

If focus changes or the target disappears, do not paste into whichever window is currently active.

### “Works all the time” realism

The editor can eliminate its own clipboard bugs, but it cannot guarantee success if the OS denies access, the compositor disconnects, or the clipboard is temporarily locked.

The practical requirement is:

- Reliable operation throughout the supported session.
- Bounded retries.
- Correct ownership.
- Explicit errors.
- No silent stale paste.
- Persistence after exit where the platform/session supports it.

On X11/Wayland, persistence after application exit is a separate ownership problem. Clipboard-manager handoff or a supported long-lived owner may be needed. This must be tested rather than assumed. [4]

---

# 11. File safety, recovery, and shutdown

This is infrastructure, not a finishing feature.

Implement it before encouraging users to edit important files.

## 11.1 Safe save

Recommended flow:

1. Capture immutable buffer snapshot.
2. Validate current disk identity/state.
3. Encode/format according to explicit save policy.
4. Write a temporary file in the same filesystem/directory when possible.
5. Flush as configured.
6. Atomically replace using the appropriate platform mechanism.
7. Preserve relevant permissions/metadata.
8. Record the saved checkpoint only after success.

Define policies for:

- Symlinks.
- Read-only files.
- Permission changes.
- Files modified externally.
- Hard links.
- Encoding failure.
- Disk-full errors.
- Rename/replace failures.

No save error should clear the dirty indicator.

## 11.2 External modification

When a file changes externally:

### Buffer clean

Offer or perform a safe reload according to configuration.

### Buffer dirty

Show a conflict state.

Offer:

```text
Reload and discard local changes
Keep local buffer
Save to another path
Compare
Explicit overwrite
```

Never silently overwrite an external change.

## 11.3 Swap/recovery storage

Suggested structure:

```text
state/
  recovery/
    <buffer-or-file-key>/
      manifest.json
      checkpoint.bin
      journal-000001.bin
      journal-000002.bin
```

Include:

- Format version.
- File identity/path.
- Base content hash.
- Encoding metadata.
- Session ID.
- Process-instance identity.
- Sequence numbers.
- Checksums.
- Timestamps.

Do not rely on PID alone for stale-lock detection.

## 11.4 Journal format

Append transaction records.

Each record should have:

```text
length
version
sequence
transaction payload
checksum
```

Recovery reads valid records until the last complete verified record.

A torn final record must not destroy the earlier journal.

## 11.5 Durability policy

Be honest about the difference between:

- Edit visible in memory.
- Edit queued for persistence.
- Edit durably flushed.

Recommended default:

- Frequent batched journaling.
- A configurable durability interval.
- Synchronous flush before clean shutdown.
- An optional strict mode that prioritizes durability over latency.

Do not promise zero loss during power failure unless the implementation’s acknowledgment and flush policy actually provides it.

## 11.6 Shutdown state machine

```text
Running
 -> QuitRequested
 -> InspectDirtyBuffersAndJobs
 -> AwaitDecision
 -> SaveOrDiscard
 -> FlushPersistentState
 -> StopServices
 -> Exit
```

Offer:

```text
Save All and Exit
Review Unsaved
Discard Explicitly and Exit
Cancel
```

Requirements:

- Save failure blocks exit.
- A canceled Save As blocks exit.
- Untitled buffers containing user work are included.
- Closing the last view of a dirty buffer triggers the same protection.
- Closing one of several views does not necessarily destroy the buffer.
- IPC and filesystem-driven close requests use the same protection.
- Running jobs are handled separately from dirty buffers.

For running jobs:

```text
Wait
Cancel jobs
Detach, only when supported
Cancel exit
```

An OS kill or power loss cannot always be prevented; recovery is the fallback.

## 11.7 Persistent undo storage

Persistent undo and crash recovery are related but different:

- **Recovery journal:** protect current unsaved work.
- **Undo archive:** preserve historical branches.

Use shared serialization infrastructure, but different retention policies.

Never prune recovery data merely because a history budget was exceeded.

---

# 12. Asynchronous commands and modern console support

## 12.1 Job model

States:

```text
Queued
Starting
Running
CancelRequested
Exited
FailedToStart
```

Each job records:

- Command.
- Shell/backend.
- Working directory.
- Environment.
- Source window/buffer.
- Selection snapshot.
- Output destination.
- Exit status.
- Start/end time.
- Cancellation support.

## 12.2 Process spawning

### Unix

- Spawn without blocking the UI.
- Separate stdin/stdout/stderr pipes.
- Process group for cancellation.
- PTY for interactive sessions.

### Windows

- Correct argument quoting.
- Explicit inherited handles.
- Pipes for noninteractive jobs.
- Job Objects where appropriate for lifecycle management.
- ConPTY for interactive sessions.

Do not construct a command line by concatenating unescaped file paths.

Distinguish:

- Direct executable invocation with argument arrays.
- Explicit shell command execution.

Shell choice should be configurable.

## 12.3 Acme command context

External jobs need context such as:

```text
ACME_WINDOW_ID
ACME_BUFFER_ID
ACME_FILE
ACME_ADDRESS
ACME_PROJECT_ROOT
ACME_INSTANCE_ROOT
ACME_ENDPOINT
```

Add legacy environment-variable compatibility only after verifying the exact reference semantics.

## 12.4 Selection pipes

Support the documented Acme meanings of:

```text
>command
<command
|command
```

Typically these correspond to feeding selected text to a process, replacing from process output, and piping selected text through a process—but use the compatibility specification for exact details.

### Asynchronous replacement rule

When a command starts:

1. Capture the source selection and revision.
2. Provide a snapshot to stdin.
3. Collect output asynchronously.
4. Validate the target range before replacing.

If the user edits that range while the command runs:

- Do not overwrite the new work.
- Preserve command output in an output window.
- Offer explicit application/replacement.

Successful replacement is one undo transaction.

## 12.5 Two console models

Do not conflate these.

### A. Acme-style command/log window

An editable text buffer containing command output.

Supports:

- Unicode.
- ANSI styles.
- Colored diagnostics.
- Progress lines.
- Clickable file locations.
- Acme selection, execution, and lookup.

This should be the default.

### B. Terminal window

A terminal grid attached to PTY/ConPTY.

Supports:

- Terminal cursor addressing.
- Alternate screen.
- Raw input.
- Terminal resizing.
- Full-screen programs if the advertised emulation supports them.

This is a separate view kind.

A full terminal cannot be represented faithfully as an ordinary editable log buffer.

## 12.6 ANSI parser

Use a streaming state machine.

It must preserve state across output chunks.

Minimum log-window support:

- UTF-8 decoding across chunk boundaries.
- SGR reset.
- Basic and bright colors.
- 256-color palette.
- True color.
- Bold/dim/italic/underline where supported.
- Carriage-return progress updates.
- Backspace.
- Erase-to-end-of-line.
- Safe OSC handling.
- Hyperlinks if deliberately supported.

Unknown sequences must be handled deterministically.

Do not execute control strings.

In particular:

- OSC clipboard writes should be disabled by default or require explicit permission.
- Hyperlinks must not automatically execute shell commands.
- Output text that looks like a command is not automatically executed.

## 12.7 Output storage

Store styles separately from text.

For long-running jobs:

- Batch updates.
- Keep the UI mutation budget bounded.
- Maintain bounded in-memory scrollback.
- Spill older output to disk when appropriate.
- Preserve ordered stream records.

Separate stdout/stderr pipes do not provide a perfect global ordering. Do not claim one unless using a transport that actually provides it.

---

# 13. Tree-sitter and lightweight completion

## 13.1 Tree-sitter integration

Per buffer:

```text
language
parser worker state
syntax tree
tree_revision
pending edit sequence
highlight spans
query version
```

Pipeline:

1. Transaction commits.
2. Record Tree-sitter-compatible edit information.
3. Worker receives snapshot and edit sequence.
4. Apply edits to the worker-owned tree.
5. Parse incrementally.
6. Run relevant queries.
7. Publish revisioned styles.

Tree-sitter input should read rope chunks through its input callback, not require whole-buffer flattening.

## 13.2 Important highlighting detail

Changed syntax ranges are useful, but not sufficient by themselves for every query and injection case.

Expand invalidation appropriately for:

- Parent scopes.
- Multiline constructs.
- Query captures spanning changed regions.
- Language injections.

## 13.3 Grammar management

Pin:

- Parser runtime.
- Language ABI.
- Grammar source.
- External scanners.
- Highlight queries.
- Licenses.

Do not download and load arbitrary native grammar libraries at runtime without a trust model.

## 13.4 Large-file policy

Configurable thresholds can disable or budget:

- Full parsing.
- Injections.
- Expensive queries.

Always retain plain text rendering.

## 13.5 Completion scope

Keep completion light:

- Current-buffer words.
- Optional open-buffer words.
- No mandatory language server.
- No automatic project-wide semantic indexing.

## 13.6 Completion index

Maintain:

```text
word -> occurrence count
word -> recency/proximity metadata
```

Update incrementally from changed text regions.

Expand edits to word boundaries before adjusting the index.

For large files, use:

- Sampling.
- Bounded indexing.
- On-demand scanning.
- Explicit disabled/limited state.

## 13.7 Ranking

Suggested priority:

1. Prefix match.
2. Same case.
3. Nearby occurrence.
4. Frequency.
5. Recency.

Exclude the currently typed occurrence when useful.

## 13.8 Completion UX

- `Ctrl+Space` opens suggestions.
- Typing may optionally trigger suggestions.
- Escape dismisses.
- Enter accepts when explicitly active.
- Tab behavior must not break indentation.

Selection replacement is one transaction.

No popup should steal input during IME composition.

---

# 14. Configuration and EditorConfig

## 14.1 Compiled Odin configuration

Use a trusted Odin source file compiled into the editor.

Suggested workflow:

```text
acme-build --config ~/.config/acme-next/config.odin
```

The build tool stages the source into a generated package with a known schema.

Avoid requiring users to modify the Odin installation’s shared package directories.

## 14.2 Configuration schema

Illustrative schema:

```odin
package config

Theme :: struct {
    body_bg:      [4]f32,
    body_fg:      [4]f32,
    tag_bg:       [4]f32,
    tag_fg:       [4]f32,
    selection_bg: [4]f32,
    selection_fg: [4]f32,
    caret:        [4]f32,
    git_added:    [4]f32,
    git_modified: [4]f32,
    git_deleted:  [4]f32,
}

Config :: struct {
    font_families:    []string,
    font_size_points: f32,
    line_height:      f32,
    ligatures:        bool,
    theme:            Theme,
}
```

The actual configuration should also support:

- Tag/body/console font roles.
- Keybindings.
- Touchpad bindings.
- Syntax style palette.
- Large-file thresholds.
- History budgets.
- Recovery interval.
- Shell configuration.
- Clipboard selection policy.
- Finder exclusions.
- Terminal settings.

## 14.3 Compile/apply workflow

`ConfigBuild` should:

1. Save the config file if requested.
2. Start an asynchronous build.
3. Display compiler output in an Acme output window.
4. Keep the existing editor running if compilation fails.
5. On success, offer restart/handoff.
6. Persist layout and recovery state before replacement.

On Windows, replacing a running executable requires a staged/versioned binary and launcher strategy.

Do not simply attempt to overwrite the running executable.

## 14.4 Trust boundary

An Odin configuration file is executable code.

Therefore:

- Only explicitly trusted user configuration is compiled.
- Never automatically compile a project-local config just because a repository contains one.
- Project layout/session files should use a non-executable format.

## 14.5 EditorConfig

Support standard semantics, not a home-grown approximation.

Important properties:

```text
root
indent_style
indent_size
tab_width
end_of_line
charset
trim_trailing_whitespace
insert_final_newline
```

Also support:

- Glob matching.
- Parent traversal.
- Property precedence.
- `unset`.
- Unsupported-property diagnostics where appropriate.

## 14.6 Effective settings layers

Recommended precedence:

```text
built-in defaults
 -> compiled user defaults
 -> project/session overrides where allowed
 -> EditorConfig file settings
 -> explicit current-buffer override
```

Keep visual preferences separate from file-format preferences.

EditorConfig should not set theme colors or font families.

## 14.7 Save-time transformations

If EditorConfig requires trimming or a final newline:

- Apply as a visible transaction.
- Make it undoable.
- Do not silently transform content after recording a “saved” checkpoint.
- Avoid modifying an in-flight save snapshot inconsistently with the visible buffer.

---

# 15. Interactive undo tree, finder, layout, and Git

## 15.1 Undo tree UI

Keep it Acme-like.

A `History` command can open a special window containing a textual tree:

```text
● 2026-11-11 14:31  saved
 └─ 14:32  typed 18 characters
     ├─ 14:33  replaced selection
     └─ 14:34  indent 6 lines   <current>
```

Interaction:

- Look/execute a node to jump.
- Preview before applying if desired.
- Navigate parent/child branches.
- Label a node.
- Show saved checkpoints.
- Inspect transaction summaries.

A graphical branch visualization can be added later, but a textual interface fits Acme immediately.

### History jump rule

Jumping history changes the active branch; it does not delete later branches.

## 15.2 Persistent history validity

On reopen:

- Verify the archive against file identity and saved content.
- If disk content differs, do not replay old edits onto unrelated content.
- Offer the old archive as an orphaned historical snapshot.
- Handle rename and move explicitly.

## 15.3 Fuzzy finder

A minimal overlay or special window should search:

- Project file paths.
- Open buffers.
- Commands.
- Recent files.

Capabilities:

- Asynchronous indexing.
- `.gitignore` handling.
- Configurable exclusions.
- Unicode paths.
- Incremental query cancellation.
- Match highlighting.
- Preview.
- Open in current/new window.

Do not recursively scan the whole project on every keystroke.

Avoid following symlink cycles.

## 15.4 Persistent project layout

Store:

- Project root.
- Columns and relative widths.
- Window order and relative heights.
- Buffer paths.
- View selections.
- Scroll anchors.
- Tags.
- Scratch buffer recovery references.
- Chosen wrap mode.
- Optional history-panel state.

Prefer logical ratios over raw pixels so layouts survive DPI/monitor changes.

Suggested format:

```text
state/projects/<project-key>/layout.json
```

Include a schema version.

## 15.5 Restore policy

On restore:

- Missing files become a clear placeholder/error state.
- Unsaved scratch content comes from recovery storage.
- Paths can be relocated deliberately.
- Commands in tags are not automatically executed.
- Previously running commands are not automatically restarted by default.
- Malformed layout data falls back safely.

## 15.6 Lightweight Git support

Version 1 should provide:

- Branch name.
- File status.
- Added/modified/deleted line indicators.
- Next/previous change.
- Optional changed-files list.

Use background `git` commands initially.

Parse machine-readable output, including NUL-separated paths where supported.

### Distinguish baselines

Useful states are:

- Working file versus index.
- Index versus HEAD.
- Unsaved buffer versus current disk/index content.

Do not label an unsaved-buffer comparison as though it were simply `git diff` on disk.

### Avoid scope creep

Do not implement:

- Rebase UI.
- Merge conflict resolution suite.
- Commit graph.
- Full staging interface.

These can remain external Acme commands.

---

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

---

# 17. Performance and efficiency requirements

Create:

```text
docs/performance-budget.md
```

All numbers below are **initial targets**, not claims.

Choose and document reference hardware before making them release criteria.

## 17.1 Interactive targets

Suggested targets:

- Typical typing core update: p95 below 8 ms.
- No ordinary UI task monopolizes the thread for more than roughly one frame.
- Continuous job output must not make cursor movement visibly lag.
- Scrolling and resizing should remain responsive at the supported refresh rate.
- Background results should be applied in bounded batches.

## 17.2 Benchmark fixtures

Use at least:

| Fixture                        | Purpose                             |
| ------------------------------ | ----------------------------------- |
| 1 MiB source file              | Normal editing                      |
| 100 MiB source/log file        | Large-file indexing and scrolling   |
| 1 GiB log file                 | Backing-store and large-file mode   |
| Single very long line          | Shaping and horizontal scrolling    |
| Mixed-script Unicode           | Font fallback and grapheme movement |
| Invalid UTF-8                  | Lossless handling                   |
| 100k-file project              | Finder scalability                  |
| Heavy process output           | Backpressure                        |
| Large undo tree                | History storage/navigation          |
| Many windows on shared buffers | Layout and snapshot overhead        |

Measure:

- Cold/warm startup.
- Time to first useful viewport.
- Time to editable state.
- Peak and steady-state memory.
- Typing latency.
- Scroll latency.
- Parse latency.
- Clipboard transfer behavior.
- Save time.
- Journal durability cost.

## 17.3 Idle behavior

The editor should not redraw expensively while idle.

If the chosen Sokol application loop does not provide adequate event-driven waiting, investigate a small platform integration change.

“Skip drawing but keep spinning at full speed” is not a good idle implementation.

## 17.4 Allocation policy

Use:

- Frame arenas for transient draw/layout data.
- Worker-local scratch arenas.
- Explicit long-lived allocators.
- Reference-counted immutable snapshots.
- Bounded caches.

Never return worker results that point into a worker’s reset scratch arena.

---

# 18. Implementation roadmap

Each milestone below is a **section of work**, not a single agent invocation.

The agent should implement one small, testable task from the active milestone per session.

Do not skip foundational milestones just because a later feature is easier to demo.

---

## M00 — Specification, feasibility spikes, and build baseline

### Deliverables

- Repository structure.
- Architecture documents.
- Acme compatibility matrix.
- Pinned toolchain/dependencies.
- Linux and Windows CI.
- Runnable Sokol sample.
- Native clipboard/DPI/IME feasibility notes.
- IPC and filesystem design decision.

### Tasks

```text
M00.01  Create repository/docs/agent workflow.
M00.02  Pin Odin, Sokol, shader tooling, and native dependencies.
M00.03  Build/run a window on Windows and Linux.
M00.04  Spike Unicode clipboard round-trip and large transfer.
M00.05  Spike mixed-DPI and text-input/IME integration.
M00.06  Spike native Wayland feasibility for chosen backend.
M00.07  Spike PTY/ConPTY and asynchronous process output.
M00.08  Prove minimal FUSE/WinFsp adapter deployment.
M00.09  Record architecture decisions and compatibility inventory.
```

### Acceptance

- Both Tier-1 OS build paths work.
- No unverified claim about Wayland, clipboard, or IME is treated as solved.
- A clear platform limitation is either resolved or explicitly blocks the affected release tier.
- FS mount deployment risk is understood before the final milestone.

---

## M01 — Application shell, platform layer, and compiled config

**Depends on:** M00

### Deliverables

- Application lifecycle.
- Logging.
- Platform service interfaces.
- Compiled configuration package.
- Basic renderer.
- Debug diagnostics window.

### Tasks

```text
M01.01  Implement lifecycle and error-reporting infrastructure.
M01.02  Add generated trusted configuration package.
M01.03  Create logical/physical coordinate conversion.
M01.04  Add native input normalization.
M01.05  Add worker/result queues with bounded capacity.
M01.06  Render basic column/tag/body rectangles.
```

### Acceptance

- Configuration edits visibly change colors/font-size settings after rebuild.
- Resize and scale changes do not crash.
- No dependency-specific code leaks into the core.

---

## M02 — Rope, transactions, anchors, and headless core

**Depends on:** M01

### Deliverables

- Persistent piece-rope.
- Text snapshots.
- Transactions.
- Buffer registry.
- Anchor transformations.
- Basic in-memory undo tree.

### Tasks

```text
M02.01  Implement immutable backing chunks.
M02.02  Implement leaves, metrics, and range iteration.
M02.03  Implement balancing and persistent root updates.
M02.04  Implement coordinate conversion.
M02.05  Implement transactions and revision tracking.
M02.06  Implement anchor transformation.
M02.07  Implement branching in-memory undo.
M02.08  Add randomized differential tests and benchmarks.
```

### Acceptance

- Randomized tests match the reference model.
- Snapshots remain valid after later edits.
- Large insert/delete operations do not flatten the entire buffer.
- Undo branches survive new edits after undo.

---

## M03 — File loading, codecs, safe save, and external changes

**Depends on:** M02

### Deliverables

- File-backed buffers.
- Chunked loading.
- Codec/EOL metadata.
- Safe save.
- File identity handling.
- External modification detection.

### Tasks

```text
M03.01  Implement canonical file identity.
M03.02  Implement background chunked loading.
M03.03  Implement UTF-8/BOM/newline policy.
M03.04  Implement explicit unsupported/invalid encoding behavior.
M03.05  Implement temporary-write/replace save.
M03.06  Implement disk-change conflict detection.
M03.07  Add failure-injection tests for save.
```

### Acceptance

- Untouched supported files round-trip correctly.
- Invalid bytes are not silently destroyed.
- Disk-full/permission/replace failure leaves the buffer dirty.
- External edits are not overwritten silently.

---

## M04 — Recovery journals, persistent history foundation, and shutdown guard

**Depends on:** M03

### Deliverables

- Recovery storage.
- Journal/checkpoint format.
- Crash replay.
- Persistent undo records.
- Safe close/quit state machine.

### Tasks

```text
M04.01  Implement versioned checksummed journal.
M04.02  Implement periodic checkpointing and rotation.
M04.03  Implement crash recovery discovery.
M04.04  Implement stale-session/lock detection.
M04.05  Persist undo transactions and branches.
M04.06  Implement dirty-buffer close/quit decisions.
M04.07  Implement save-failure exit blocking.
M04.08  Add kill-at-random-point recovery tests.
```

### Acceptance

- A torn last record does not invalidate prior records.
- Unsaved named and untitled buffers are recovered.
- No close path bypasses dirty checks.
- Recovery and history retention are separate.

---

## M05 — Unicode text renderer, fonts, and DPI

**Depends on:** M02; integrates M03/M04

### Deliverables

- FreeType/HarfBuzz integration.
- Unicode segmentation/bidi support.
- Font discovery/fallback.
- Glyph cache.
- Visible-line rendering.
- Correct hit testing.

### Tasks

```text
M05.01  Bind and pin font/shaping/Unicode libraries.
M05.02  Implement font discovery and role selection.
M05.03  Implement glyph atlas/cache lifecycle.
M05.04  Implement shaping and positioned runs.
M05.05  Implement selection/caret hit testing from shaped runs.
M05.06  Implement DPI change invalidation.
M05.07  Implement huge-line bounded rendering.
M05.08  Add mixed-script/DPI visual fixtures.
```

### Acceptance

- Combining characters and emoji do not produce invalid cursor positions.
- Selection geometry matches displayed text.
- Mixed-DPI movement preserves logical layout.
- Huge lines do not synchronously shape in full.

---

## M06 — Editing input, modern shortcuts, clipboard, and indentation

**Depends on:** M04, M05

### Deliverables

- Basic editor usable by keyboard.
- Native copy/cut/paste.
- Selection extension.
- Indent/outdent.
- IME support.

### Tasks

```text
M06.01  Implement movement and selection actions.
M06.02  Implement keyboard binding resolver.
M06.03  Implement text-input versus key-command separation.
M06.04  Implement native clipboard service on both OS families.
M06.05  Implement delayed-paste target validation.
M06.06  Implement multiline indent/outdent transaction.
M06.07  Implement IME preedit/commit handling.
M06.08  Add clipboard interoperability tests.
```

### Acceptance

- Copy/paste works with external applications.
- Large Unicode transfers work.
- Clipboard failure is visible, not replaced by stale content.
- AltGr and IME do not trigger erroneous shortcuts.
- Indentation is one undo step.

---

## M07 — Acme columns, windows, tags, mouse workflow, and lookup

**Depends on:** M06

### Deliverables

- Real Acme-style layout.
- Shared-buffer windows.
- Editable tags.
- Mouse state machine.
- Touchpad alternatives.
- Directory/lookup behavior.

### Tasks

```text
M07.01  Implement columns/window layout and dragging.
M07.02  Implement buffer/view separation in UI.
M07.03  Implement tag editing and generated command state.
M07.04  Implement original mouse actions/chords.
M07.05  Implement modifier-assisted gestures.
M07.06  Implement Look token expansion and file opening.
M07.07  Implement directory windows and error windows.
M07.08  Add compatibility scenarios for window behavior.
```

### Acceptance

- Multiple views share text but not selection/scroll.
- Middle/right actions match the compatibility specification.
- Touchpad users can execute/look without physical three-button hardware.
- Closing one view does not destroy a shared dirty buffer.

---

## M08 — Address language, internal commands, and Acme Edit

**Depends on:** M07

### Deliverables

- Command parser/registry.
- Address parser.
- Compatible regex behavior.
- `Edit` interpreter.
- Built-in command coverage.

### Tasks

```text
M08.01  Implement command dispatch and context.
M08.02  Implement line/character/range addresses.
M08.03  Implement compatible regex address semantics.
M08.04  Implement documented Edit command subset in dependency order.
M08.05  Complete required Edit coverage.
M08.06  Add cancellable snapshot-based execution for expensive edits.
M08.07  Implement atomic multi-buffer validation where needed.
M08.08  Add differential compatibility fixtures.
```

### Acceptance

- Do not mark complete with only search-and-replace implemented.
- `Edit` operations are undoable as coherent transactions.
- Long regex/edit operations are cancellable.
- Multi-buffer stale conflicts do not create partial unintended edits.

---

## M09 — Asynchronous external commands and selection pipes

**Depends on:** M08

### Deliverables

- Cross-platform job service.
- Output/error windows.
- Working-directory/environment context.
- Cancellation.
- Selection pipes.

### Tasks

```text
M09.01  Implement process spawning and handle ownership.
M09.02  Implement nonblocking stdin/stdout/stderr flow.
M09.03  Implement job lifecycle and Stop command.
M09.04  Implement contextual environment/cwd.
M09.05  Implement output-window batching/backpressure.
M09.06  Implement selection stdin/output replacement.
M09.07  Implement stale-target conflict behavior.
M09.08  Integrate running-job quit decisions.
```

### Acceptance

- Long commands do not freeze editing.
- Cancellation cleans up child processes appropriately.
- Output floods remain bounded.
- A late pipe result cannot overwrite newer selection edits.

---

## M10 — Unicode ANSI console and PTY/ConPTY terminal mode

**Depends on:** M09

### Deliverables

- Streaming console decoder.
- Styled log output.
- Progress handling.
- Optional terminal view.
- Terminal resize/input integration.

### Tasks

```text
M10.01  Implement chunk-safe UTF-8 decoder.
M10.02  Implement ANSI state machine and SGR styles.
M10.03  Implement CR/backspace/erase progress behavior.
M10.04  Implement hyperlink/control-sequence safety policy.
M10.05  Implement PTY/ConPTY process mode.
M10.06  Integrate a tested terminal-emulation layer.
M10.07  Implement resize, alternate screen, and raw input.
M10.08  Test advertised terminal capabilities.
```

### Acceptance

- Split escape sequences decode correctly.
- Colored compiler output is readable and selectable.
- Terminal cell positions are not confused with editor byte offsets.
- Do not advertise xterm-level compatibility if only ANSI colors are implemented.

---

## M11 — EditorConfig and polished compiled-config workflow

**Depends on:** M06, M09

### Deliverables

- EditorConfig resolver/cache.
- Effective buffer settings.
- Save-time transformations.
- `ConfigBuild` flow.
- Safe application handoff.

### Tasks

```text
M11.01  Implement tested EditorConfig resolution.
M11.02  Apply indentation settings.
M11.03  Apply explicit EOL/charset save policies.
M11.04  Implement undoable trailing-space/final-newline formatting.
M11.05  Add asynchronous config-build command.
M11.06  Add staged restart/handoff.
M11.07  Add config validation/diagnostics.
```

### Acceptance

- Official/compatible EditorConfig fixtures pass.
- Failed compilation leaves the running editor unchanged.
- Project-local executable configuration is not compiled automatically.
- Restart preserves unsaved work and layout.

---

## M12 — Incremental Tree-sitter highlighting

**Depends on:** M02, M05, M11

### Deliverables

- Parser worker integration.
- Rope input callbacks.
- Incremental tree edits.
- Highlight queries.
- Large-file budget.

### Tasks

```text
M12.01  Pin runtime/bindings/initial grammars.
M12.02  Implement rope-backed TSInput.
M12.03  Convert transactions to parser edits.
M12.04  Implement worker-owned incremental trees.
M12.05  Implement revisioned highlight publication.
M12.06  Implement invalidation and query scope expansion.
M12.07  Add initial language set and plain-text fallback.
M12.08  Add parser budget/cancellation tests.
```

### Acceptance

- Typing does not wait for parsing.
- Stale highlights are discarded or clearly bounded.
- Selection remains readable over all syntax colors.
- Parser failure never prevents editing.

---

## M13 — Lightweight buffer completion

**Depends on:** M06, M12

### Deliverables

- Incremental word index.
- Completion ranking.
- Popup.
- Transactional acceptance.

### Tasks

```text
M13.01  Implement word-boundary token extraction.
M13.02  Implement incremental count/index updates.
M13.03  Implement ranking and bounded result count.
M13.04  Implement popup input/focus rules.
M13.05  Implement completion transaction.
M13.06  Implement large-file limits.
```

### Acceptance

- No mandatory semantic server.
- Completion acceptance is one undo operation.
- Tab indentation still works.
- IME composition is not interrupted.

---

## M14 — Interactive persistent undo tree

**Depends on:** M04, M07

### Deliverables

- `History` window.
- Branch visualization.
- Node navigation.
- Persistent archive validation.
- Retention management.

### Tasks

```text
M14.01  Expose history model to a special buffer/view.
M14.02  Render textual/visual branch tree.
M14.03  Implement jump/preview actions.
M14.04  Persist labels/checkpoints/branch selection.
M14.05  Validate history against reopened disk content.
M14.06  Implement orphaned-history handling.
M14.07  Implement safe budget/pruning policy.
```

### Acceptance

- Branches survive restart.
- History is not replayed onto unrelated file content.
- Pruning never destroys the current recovery path.
- Jumping branches preserves other branches.

---

## M15 — Fuzzy finder and project indexing

**Depends on:** M07, M09

### Deliverables

- Project path index.
- File/buffer/command finder.
- Preview.
- Ignore rules.
- Async cancellation.

### Tasks

```text
M15.01  Implement bounded project traversal.
M15.02  Implement ignore and symlink policy.
M15.03  Implement fuzzy ranking/highlight spans.
M15.04  Implement finder overlay/special window.
M15.05  Implement preview and open actions.
M15.06  Implement incremental refresh/cancellation.
M15.07  Benchmark large-project queries.
```

### Acceptance

- A 100k-path project does not rescan per key.
- Unicode paths work.
- Stale query results do not replace current results.
- Symlink cycles cannot hang indexing.

---

## M16 — Persistent per-project layout and session restoration

**Depends on:** M04, M07, M15

### Deliverables

- Versioned session format.
- Layout autosave.
- Scratch references.
- Restore/relocation logic.

### Tasks

```text
M16.01  Serialize columns/window order and ratios.
M16.02  Serialize view anchors and tags.
M16.03  Persist scratch/recovery references.
M16.04  Implement debounced safe writes.
M16.05  Implement restore with missing-file states.
M16.06  Implement schema migration/fallback.
M16.07  Implement explicit project relocation.
```

### Acceptance

- Layout restores across DPI changes.
- Corrupt layout data does not lose buffer recovery data.
- Tags are restored without auto-executing commands.
- Previously running jobs are not silently restarted.

---

## M17 — Lightweight Git state and change navigation

**Depends on:** M09, M15, M16

### Deliverables

- Branch/status.
- Changed-file markers.
- Buffer line-change indicators.
- Next/previous change.

### Tasks

```text
M17.01  Detect repository/worktree context.
M17.02  Parse machine-readable status safely.
M17.03  Compute file/index/HEAD baseline metadata.
M17.04  Compute unsaved-buffer change hunks.
M17.05  Render compact markers and tag status.
M17.06  Implement hunk navigation.
M17.07  Add debounce/cancellation and non-Git fallback.
```

### Acceptance

- Paths containing whitespace/newlines are handled correctly.
- Git work is off the UI thread.
- Baseline distinctions are correct.
- The editor remains fully usable without Git installed.

---

## M18 — Modern local IPC and command-line client

**Depends on:** M08, M09, M16

### Deliverables

- Socket/named-pipe server.
- Versioned protocol.
- `acmectl`.
- Revisioned edits.
- Event subscriptions/interception.

### Tasks

```text
M18.01  Implement framing/version negotiation.
M18.02  Implement local authorization/ACLs.
M18.03  Implement read/list/create operations.
M18.04  Implement revisioned mutation operations.
M18.05  Implement chunked text transfer.
M18.06  Implement event stream/sequence handling.
M18.07  Implement interception/reinjection lease state.
M18.08  Implement acmectl and script examples.
M18.09  Add disconnect/abuse/conflict tests.
```

### Acceptance

- IPC edits go through ordinary transactions and undo.
- Stale writes return explicit conflicts.
- Disconnects do not leave input blocked.
- No remote interface is enabled by default.

---

## M19 — Filesystem projection and live filesystem adapters

**Depends on:** M18

### Deliverables

- Driverless state projection.
- Request/reply mailbox.
- Event segments.
- FUSE adapter.
- WinFsp adapter.
- Acme-style live entries.

### Tasks

```text
M19.01  Implement revisioned ordinary-file projections.
M19.02  Implement atomic request mailbox and replies.
M19.03  Implement event retention/gap reporting.
M19.04  Implement Unix mounted adapter.
M19.05  Implement Windows mounted adapter.
M19.06  Implement per-open addr/data/event semantics.
M19.07  Implement safe cancellation/unmount/shutdown.
M19.08  Add shell-based read/write/execute examples.
M19.09  Add filesystem compatibility tests.
```

### Acceptance

- State is inspectable through normal filesystem tools.
- Projection revisions are explicit.
- Full live semantics work through the mounted adapters.
- Mounted reads/writes do not duplicate editor logic.
- No whole-buffer export happens on every keystroke.
- Filesystem-driven close/save obeys ordinary safety rules.

---

## M20 — Compatibility completion, hardening, packaging, release

**Depends on:** all required milestones

### Deliverables

- Completed compatibility matrix.
- Performance report.
- Platform support report.
- Installers/packages.
- Recovery documentation.
- Security review.
- Release checklist.

### Tasks

```text
M20.01  Close required Acme compatibility gaps.
M20.02  Run full cross-platform integration matrix.
M20.03  Run performance and large-file benchmarks.
M20.04  Run crash/disk-error/clipboard stress tests.
M20.05  Audit resource ownership and cancellation.
M20.06  Audit dependency licenses and packaging.
M20.07  Package runtime/native FS dependencies.
M20.08  Document limitations and migration.
M20.09  Prepare release candidate and soak testing.
```

### Acceptance

No required feature is declared finished solely because:

- A demo exists.
- The happy path works.
- One OS passes.
- A stub interface has been created.
- The agent believes it “should work.”

---

# 19. What the agent should implement every time

This is the operational part that prevents the project from becoming an impressive pile of unfinished features.

## 19.1 One active milestone

`NEXT.md` identifies:

- Active milestone.
- Current task.
- Prerequisites.
- Allowed scope.
- Acceptance criteria.
- Known blockers.
- Exact next action.

The agent works on the earliest unblocked task in the active milestone.

It does not jump to a visually attractive later feature.

## 19.2 One vertical slice per session

A session should implement something like:

> “Add native Windows clipboard read with Unicode conversion, bounded retries, and adapter tests.”

Not:

> “Implement the entire clipboard subsystem and all editor input.”

And not:

> “Create empty clipboard interfaces and mark clipboard done.”

Each task should end with observable behavior or a tested invariant.

## 19.3 Required session sequence

Every agent session:

1. Read `AGENTS.md`.
2. Read `NEXT.md`.
3. Read the active milestone in `ROADMAP.md`.
4. Inspect existing code and tests.
5. Confirm prerequisites.
6. Write a short implementation plan.
7. Implement the smallest complete slice.
8. Add or update tests.
9. Run relevant tests.
10. Run build/static checks.
11. Update documentation if a contract changed.
12. Update roadmap status.
13. Write the exact next task.
14. Summarize changes, validation, and remaining risks.

## 19.4 Definition of done for an individual task

A task is complete only when:

- Behavior is implemented.
- Ownership/lifetime rules are clear.
- Errors are handled.
- Cancellation is handled where applicable.
- Relevant tests exist.
- Tests were actually run, or inability to run is explicitly recorded.
- No hidden stub remains in the task’s acceptance path.
- Documentation matches behavior.
- Supported-platform status is accurate.

If Windows could not be tested, write:

```text
Implemented; Linux tested; Windows validation pending.
```

Do not write:

```text
Cross-platform complete.
```

## 19.5 Scope guard

The agent may fix a prerequisite bug if necessary.

It must not:

- Rewrite unrelated modules.
- Change dependency versions casually.
- Replace the architecture to simplify one task.
- Introduce a new UI framework.
- Bypass transactions.
- Silence failing tests.
- Remove compatibility requirements to make progress appear faster.

Architecture changes require an ADR.

---

# 20. Suggested `AGENTS.md`

```markdown
# Agent Operating Rules

## Product identity

This is an Acme reimagining in Odin and Sokol.

Preserve:

- Editable tags and text-oriented commands.
- Columns and windows.
- Select / execute / look.
- Original supported mouse chording.
- External programmability.
- Acme addressing and required Edit semantics.

Modernize:

- Native clipboard.
- Unicode/fonts/DPI.
- Async jobs.
- Safe save/recovery.
- Modern keyboard/touchpad access.
- Versioned local IPC and filesystem access.

Do not turn the project into a conventional IDE.

## Before changing code

1. Read NEXT.md.
2. Read the active ROADMAP.md milestone.
3. Read relevant architecture and ADR documents.
4. Inspect existing implementation and tests.
5. Confirm prerequisites are complete.

## Work selection

Implement exactly one small, complete, testable task from the
active milestone.

Do not skip ahead unless a documented prerequisite requires it.

## Core invariants

- All buffer mutations go through transactions.
- The editor core has one mutation owner.
- Workers use immutable snapshots.
- Background results carry source revisions.
- Stale results never silently overwrite current state.
- Buffers and views are separate.
- Byte, scalar, grapheme, line, pixel, and terminal-cell positions
  are distinct types/concepts.
- No whole-buffer flattening on ordinary rendering/edit paths.
- No silent destructive encoding conversion.
- No close path bypasses dirty-buffer protection.
- No unlimited queues, output buffers, or caches.
- No native resource lifetime may be implicit.

## Platform policy

Do not claim cross-platform completion without validation.

Use platform adapters for:

- Clipboard.
- Processes/PTY.
- Fonts.
- DPI/IME.
- IPC.
- Filesystem mounting.

Do not use shell clipboard commands as the primary implementation.

## Safety policy

- Save failures leave buffers dirty.
- Disk conflicts require explicit handling.
- Recovery data is not pruned like ordinary history.
- IPC and filesystem writes use the same core actions.
- Output text is not automatically executed.
- Project-local Odin config is not automatically compiled.

## Validation

For every task:

- Add/update relevant tests.
- Run relevant tests.
- Run applicable builds/checks.
- Record exact commands and outcomes.
- State what was not tested.

Never claim tests passed unless they were run.

## Completion

Update:

- ROADMAP.md
- NEXT.md
- Relevant docs/ADRs
- Session summary

A stub is not a completed feature.

## End-of-session report

Report:

1. Task completed.
2. Files/modules changed.
3. User-visible behavior or invariant added.
4. Tests/builds run and results.
5. Known limitations/blockers.
6. Exact next task.
```

---

# 21. Suggested `NEXT.md` format

```markdown
# Current work

Active milestone: M02 — Rope and transactions
Current task: M02.03 — Persistent root updates and balancing

## Goal

Implement insertion and deletion without mutating existing roots.

## Prerequisites

- [x] Immutable backing chunks
- [x] Leaf range iteration
- [x] Metric aggregation
- [ ] Persistent balancing

## Allowed scope

- src/text/
- tests/property/
- bench/text/

## Acceptance

- Existing snapshots remain byte-identical after edits.
- Randomized insert/delete tests match the reference model.
- Tree invariants hold after every operation.
- No whole-buffer copy for a small edit.
- Allocation ownership is documented.

## Validation commands

Record actual project commands here.

## Known blockers

None.

## Next after completion

M02.04 — Coordinate conversion and line lookup.
```

## 21.1 Session handoff format

```markdown
## Session result

Task:
M02.03

Implemented:

- Persistent insert/delete path.
- Node split/merge/rebalance.
- Root snapshot retention.

Validated:

- Command: ...
- Result: ...
- Command: ...
- Result: ...

Not validated:

- Windows benchmark run.

Remaining risk:

- ...

Next task:
M02.04 — Coordinate conversion and line lookup.
```

---

# 22. Testing strategy

A project like this needs more than unit tests.

## 22.1 Unit tests

- Command parsing.
- Address parsing.
- Metrics.
- Anchor transformation.
- EditorConfig resolution.
- ANSI parser state transitions.
- Protocol framing.
- Undo branch navigation.

## 22.2 Property tests

- Rope versus reference model.
- Edit/undo round trips.
- Coordinate conversions.
- Transaction range validation.
- Journal replay.
- Randomized ANSI chunk boundaries.

## 22.3 Integration tests

- Open/edit/save/reopen.
- Shared-buffer windows.
- Async command replacement.
- IPC mutations.
- Filesystem reads/writes.
- Project restoration.
- Git status parsing.

## 22.4 Platform tests

- Clipboard interoperability.
- Large clipboard transfers.
- IME.
- DPI.
- File replacement.
- Unicode filenames.
- Process cancellation.
- PTY/ConPTY.
- Named-pipe ACLs.
- FUSE/WinFsp shutdown.

## 22.5 Crash tests

Inject failure:

- Before journal write.
- During journal write.
- Before flush.
- During checkpoint rotation.
- During save.
- After temporary save but before replace.
- During layout save.
- During process output spill.

Verify recovery from every complete durable prefix.

## 22.6 Compatibility tests

Use a corpus of interaction and command scenarios from the pinned Acme implementation.

Compare:

- Resulting text.
- Selections.
- Window lifecycle.
- Address evaluation.
- Command behavior.
- Event handling.

Visual modernization can differ. Semantic differences must be explicit.

## 22.7 Visual tests

Fixtures for:

- Tag/body colors.
- Syntax/selection interaction.
- Mixed scripts.
- Fallback fonts.
- Fractional DPI.
- RTL/bidi controls.
- Long lines.
- Git markers.
- Completion popup.
- Undo tree.

GPU screenshot tests may need tolerances; core geometry tests should remain deterministic.

---

# 23. Highest-risk parts

These should drive early spikes and careful review.

| Risk                           | Why it matters                                   | Mitigation                                                           |
| ------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------- |
| Clipboard ownership            | Platform semantics differ substantially          | Native adapters, interoperability tests, explicit persistence policy |
| IME with chosen Sokol revision | Text input APIs may be insufficient              | Early platform spike and native bridge if needed                     |
| Unicode coordinates            | Bytes, scalars, graphemes, and pixels differ     | Typed boundaries and conversion tests                                |
| Full Acme `Edit` compatibility | Easy to implement an incomplete approximation    | Reference corpus and dedicated interpreter milestone                 |
| Async selection pipes          | Late output can destroy newer edits              | Snapshot capture and revision/range validation                       |
| Persistent undo                | History can mismatch changed disk content        | Hash/checkpoint validation and orphan handling                       |
| Live filesystem semantics      | Regular files cannot mimic every device behavior | Canonical IPC plus real mount adapters                               |
| Large-file rendering           | A rope alone does not solve huge-line work       | Bounded shaping and explicit large-file mode                         |
| Process output floods          | Unlimited queues destroy responsiveness          | Backpressure, batching, spill-to-disk                                |
| Windows save/restart semantics | Different executable/file replacement rules      | Native replace APIs and staged launcher                              |
| Agent scope drift              | Easy to accumulate superficial features          | One active milestone and strict acceptance gates                     |

---

# 24. Recommended first usable release cuts

Do not wait for every advanced feature before having a useful internal build.

## Internal Alpha A — Safe text editor foundation

Through M06:

- Rope.
- Safe save.
- Recovery.
- Undo.
- Unicode fonts.
- Clipboard.
- Modern keyboard input.

This is not yet an Acme replacement, but it is safe enough for controlled use.

## Internal Alpha B — Acme workflow

Through M09:

- Columns.
- Tags.
- Mouse/touchpad workflow.
- Look.
- Address/Edit.
- Async commands.

This is the first release that should genuinely feel like Acme.

## Beta — Modern daily-driver features

Through M17:

- ANSI console.
- EditorConfig.
- Tree-sitter.
- Completion.
- Persistent undo UI.
- Finder.
- Layout.
- Git indicators.

## Release candidate — Programmable editor

Through M20:

- Modern IPC.
- Filesystem projection.
- Live mounted filesystem adapters.
- Compatibility hardening.
- Packaging.
- Cross-platform validation.

---

# Final recommendation

Build around these five commitments:

1. **A persistent rope and transaction engine are the center of the editor.**
2. **Acme’s selection/execute/look and text-interface model remain the product identity.**
3. **Native clipboard, Unicode, DPI, file safety, and async execution are foundational—not optional polish.**
4. **Modern IPC is canonical, while filesystem access remains a supported first-class interface.**
5. **The coding agent completes one tested vertical slice at a time, following the active milestone and writing an exact handoff.**

The most important practical rule is:

> **Do not spend the first month adding highlighting, a finder, and Git markers to an unsafe text widget. Build the text model, platform integration, transaction semantics, and recovery guarantees first.**

### References

1. Rob Pike, _Acme: A User Interface for Programmers_: https://9p.io/sys/doc/acme/acme.html
2. Odin ecosystem/bindings references: https://github.com/jakubtomsu/awesome-odin and https://codeberg.org/mgavioli/odin-harfbuzz
3. Odin Tree-sitter bindings: https://github.com/laytan/odin-tree-sitter
4. Clipboard ownership and platform behavior overview: https://wiki.archlinux.org/title/Clipboard
