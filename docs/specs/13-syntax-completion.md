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
