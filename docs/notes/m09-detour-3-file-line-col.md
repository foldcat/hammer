# M09.detour-3 — Button-3 Look on `file:line:col`

**Status:** done on Linux/X11. Windows source-checks with pinned Odin
`dev-2026-11`; Windows execution is unvalidated.

## Behavior

Button 3 (Look) already jumped to `file:line`. It now also accepts a
trailing column: right-clicking `file:line:col` opens (or activates) the
file and places the caret at that line and one-based scalar (rune)
column. A column past the line end clamps to the end of the line rather
than discarding the jump, matching Acme's column walk that never leaves
the line.

A line-only jump (`file:line`) now selects (highlights) the whole target
line, matching Acme's line address; the caret lands at the line start and
the viewport scrolls to show it from the left. A column jump
(`file:line:col`) places the caret at that exact column and highlights the
line from its start up to the column, so the destination is visible while
the caret marks the precise position.

If a bare basename is not found in the source directory, Look searches the
source directory's subtree (bounded: 16 levels, 4096 entries, hidden and
build/dependency directories skipped) for a matching file before falling
back to literal search. This makes compiler output like
`reverb_http.adb:169:44` open `src/reverb_http.adb` when hammer was
launched at the project root and the source directory is a subdirectory.

- `target.txt:12` → line 12 selected (no column).
- `target.txt:12:34` → line 12 highlighted up to column 34, caret at column 34.
- `C:\work\target.txt:9:3` → caret at line 9, column 3; the drive colon
  never matches a numeric segment, so Windows paths parse as before.
- `target.txt:12:` / `target.txt:12:34:` → a trailing colon is an empty
  suffix (grep/compiler output like `file:line: message`); it is stripped
  and parsed as line (or line+column).
- Invalid suffixes (`target.txt:`, `:2`, `:0`, `:x`, overflow, and the
  same forms for the column) fall through to no suffix, so the whole
  text is treated as a path and the existing literal-search fallback
  still applies.

Columns are interpreted as scalar (rune) offsets via
`rope.tree_line_col_to_byte`, consistent with the address language's
character addressing. After a column jump, `editor_reveal_caret` scrolls
horizontally so a column beyond the viewport is visible (Truncate mode;
a no-op under Soft wrap where the line wraps). A line jump resets the
horizontal offset to zero so the line starts at the left edge.

## Files

- `src/core/mouse/look.odin` — `Look_Path.col`, `last_colon`,
  `parse_positive_decimal`, trailing-colon stripping, and the two-suffix
  parse in `parse_look_path`.
- `src/look_ui.odin` — `editor_apply_look_line` renamed to
  `editor_apply_look_position` (line + column), `editor_line_content_end`
  (line end without the trailing break), column clamping, line
  selection, the `col=%d` log field, and the bounded subdirectory search
  (`editor_try_open_look`, `editor_find_basename_under`,
  `editor_search_directory`, `editor_look_skip_dir`).

## Tests

`tests/unit/mouse/text_test.odin` covers `file:line:col` parsing,
Windows-path column parsing, leading-zero normalization, trailing-colon
stripping, and invalid line/column suffix rejection, plus token expansion
of a `file:9:3` reference. `tests/integration/look/x11_harness.py` gained
a scenario that right-clicks a `coltarget.txt:1:5` reference whose file
lives in a `sub/` directory, verifies the `line=1 col=5` open log, then
types and saves to prove the caret landed at the fifth column (exercising
the subdirectory search); the existing `file:line` scenario now types over
the selected line, proving the line is highlighted on a line-only jump.

## Validation

```text
odin test tests/unit/mouse -vet -collection:hammer=src  -> 16/16 passed
odin run make.odin -file -- look-test --no-config       -> all 7 scenarios passed (incl. file:line:col)
odin run make.odin -file -- test                        -> all core unit suites passed
odin run make.odin -file -- view-test --no-config       -> passed
odin run make.odin -file -- builtin-test                -> passed
odin check src -vet -collection:sokol=third_party/sokol/sokol -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true -> passed
```

## Notes

Input with three or more numeric colon-suffixes (e.g. `a:1:2:3`) is
ambiguous; the last two numeric segments are read as line and column and
the rest becomes the path. This is not a regression for real references
and matches the "last two numbers" reading.

Windows native execution and Wine were not exercised (pre-existing
build/run blocker); Windows is source-checked only, as with the rest of
M09.
