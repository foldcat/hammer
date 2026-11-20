# M09.detour-1 — Immutable generated tag commands + editable filepath

**Status:** done on Linux/X11. Windows source-checks with pinned Odin
`dev-2026-11`; Windows execution is unvalidated.

## Behavior

A window tag is `<filepath> <commands> | <user text>` (e.g.
`source.txt Del Put | `). The generated commands region — from after the
leftmost filepath token to the ` | ` delimiter — is immutable against every
text mutation:

- Typing or paste at a caret/replacement whose insertion point falls inside
  the commands region is rejected (`tag: generated commands are immutable`).
- Deletion (backspace, delete, word-delete, cut) whose caret or selection falls
  inside the commands region is rejected. Arrow keys still move the caret
  through the region, so it can be navigated back to the filepath.
- Indentation (Tab) inside the commands region is rejected; Tab cannot insert a
  tab into the immutable text.
- The leftmost filepath token stays editable, so a new name/path can be typed.

`Get` (with no argument) reads the leftmost filepath token from the tag and
reloads that file, so editing the name and running `Get` opens a different file.
`Get <arg>` is unchanged.

Blank (untitled) file buffers — `New` with no path — have no real filepath to
protect, so their whole tag is editable, including the generated commands region
(`lock_commands` is false for them).

### Saving a new file from a blank buffer

An untitled file buffer can be saved by typing its path into the leftmost tag
token and running `Put`:

- Typing a non-`New` path into the leftmost token of an untitled buffer makes
  the generated commands become `Del Put` (a commands-only refresh, so the
  caret stays in the name while typing).
- Middle-clicking `Put` resolves that token to a path and writes the buffer
  there with `Must_Not_Exist` (no-clobber); on success the buffer adopts the
  path and becomes a normal named, clean file buffer. `Put` with no path (or
  the placeholder `New`) errors rather than guessing.

## Files

- `src/core/tag/tag.odin` — `filepath_end` tracking, `lock_commands`,
  `edit_allowed`, `deletion_allowed`, `filepath`, `rediscover`,
  `refresh_commands`.
- `src/editor.odin` — `editor_tag_constrain` (typing + deletion gate in
  `editor_perform`), `editor_indent_active` (Tab/Outdent gate), the
  filepath-change commands refresh, and `editor_save_buffer_as`.
- `src/clipboard_views.odin` — tag paste + cut gates + boundary rediscovery.
- `src/command_ui.odin` — `Get` reads `tagstate.filepath`; `Put` saves an
  untitled buffer to its typed path.
- `src/look_ui.odin` — `editor_file_basename` helper.
- `src/view_ui.odin` — `editor_window_tag_locked` (clears the lock for blank
  buffers), `editor_window_commands`, `editor_tag_filepath_token`,
  `editor_active_untitled_file`.

The boundaries are rediscovered after every successful tag edit (`rediscover`),
so a prefix deleted by a whole-tag replacement does not leave stale offsets
blocking later input.

## Tests

`tests/unit/tag/tag_test.odin` covers `filepath_boundary`, `edit_allowed`,
`deletion_allowed`, `filepath`, the unlocked (blank) tag, and `refresh_commands`
(name/caret preservation and the no-op path). The `tag-test` X11 harness covers:
typing, backspace, and Tab are blocked in the commands region; editing the
filepath then `Get` reloads the new file; a blank buffer's whole tag is
editable; and typing a path then middle-clicking `Put` writes the new file.

## Validation

```text
odin test tests/unit/tag -vet -collection:hammer=src          -> 7/7 passed
odin run make.odin -file -- test                              -> all core suites passed
odin run make.odin -file -- tag-test --no-config              -> detour + blank-buffer + save-new-file scenarios passed on Linux/X11
odin run make.odin -file -- builtin-test                      -> passed (no regression)
odin check src -vet -collection:sokol=third_party/sokol/sokol -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true -> passed
git diff --check                                              -> passed
```

## Notes

`Get` with an edited (different) filepath still leaves the buffer dirty and does
not update `buffer.path` — that is the pre-existing `Get <path>` behavior, not
part of this detour. File names containing spaces are treated as "first token =
filepath", so the immutability boundary is approximate for those rare names.
`Put` on an untitled buffer resolves the typed path relative to the window's
source directory (the working directory for a fresh blank buffer) and refuses to
overwrite an existing file.
