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
