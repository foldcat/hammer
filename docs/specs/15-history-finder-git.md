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
