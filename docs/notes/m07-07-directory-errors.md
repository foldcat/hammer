# M07.07 — Directory windows and error windows

**Status:** done on Linux/X11. Windows source type-checking passes; native
Windows/Wine runtime was not exercised.

## Directory windows

`src/core/directory/directory.odin` reads one directory without recursion and
returns an owned UTF-8 snapshot. Entries are sorted by filename and distributed
column-major into three balanced lanes. Lane padding uses Unicode monospace
cell widths and four spaces between lanes; directories receive the platform
path separator as a suffix. Reads default to at most 4096 entries and 1 MiB.
Both raw names and formatted padding count against the byte budget. Missing
paths, non-directories, iteration failures, invalid UTF-8, empty names, control
characters, allocation failures, and limit overflows return structured errors
without a partial listing.

`editor_alloc_path_buffer` is shared by startup and Look. Regular files retain
the existing load/decode path; directories become revision-0 `Directory`
buffers whose owned path ends in a separator. Directory tags contain the full
listing path and `Del Get`; `Put` is not offered. Look resolves entries against
the directory itself rather than its parent, so nested directories and files
work. Existing normalized paths still activate their existing buffer.

Startup creates one left window for the requested file, directory, or an
untitled buffer, plus one right-column window listing the process working
directory. There is no longer a second default untitled window. The explorer is
an ordinary independent directory buffer and participates in the same layout,
Look, and close paths as other windows.

Directory reads are synchronous in this slice, as file Look loads were in
M07.06. Executing `Get` to refresh a listing remains with the internal command
work in M08; this task implements the generated directory tag and window
behavior, not the full command registry.

## Error windows

Recoverable errors passed to `editor_report` are still logged and are also
shown in one reusable global `+Errors` window in the last column. The first
message initializes a clean `Errors` buffer; later messages append through a
`.Command_Output` transaction and transform same-buffer view selections. The
window is capped at 256 KiB. Failure to allocate, place, or append to the error
window is logged without recursively trying to create another error window.

Creating an error window does not activate it. This preserves the originating
document for subsequent clipboard, editing, and save actions. Automatic output
advances `saved_revision` only when the buffer was clean beforehand. If the
user has edited `+Errors`, later output leaves it dirty and close/quit remains
blocked. Directory and error buffers cannot be written through the file-save
path; user edits to either retain the ordinary dirty-close protection.

Buffer/view/layout placement now has one rollback path shared by Look and error
windows. Failure releases the buffer and any partially added layout/view/tag
resources.

## Regression coverage

Five `tests/unit/directory` tests cover sorted/Unicode output, directory
suffixes, empty and non-directory inputs, missing paths, invalid options, entry
and byte limits, exact-limit success, and ambiguous control-character names.
The package is included in `make.odin`'s `test` target.

`tests/integration/directory/x11_harness.py`, exposed as `directory-test`, uses
an isolated sandbox and real X11 input. Its six scenarios cover startup
directory creation, relative file opening and independent save, nested
directory/file navigation, error-window reuse and accumulation, preservation
of user-dirty error buffers across automatic output, and clean shutdown after
undoing the user edit. The mouse suite's final view count now includes the
expected error window created by its empty-clipboard scenario.

## Validation

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin test tests/unit/directory -vet -collection:hammer=src
    -> 5/5 passed, allocator tracking clean
odin run make.odin -file -- directory-test --no-config
    -> all six directory/error X11 checks passed
odin run make.odin -file -- look-test --no-config
    -> all six Look/file-opening checks passed
odin run make.odin -file -- view-test --no-config
    -> all four independent-buffer/view checks passed
odin run make.odin -file -- tag-test --no-config
    -> all editable/generated-tag checks passed
odin run make.odin -file -- mouse-test --no-config
    -> all mouse/modifier/chord checks passed
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save/dirty-close checks passed
odin run make.odin -file -- layout-test --no-config
    -> all six layout checks passed with the default explorer
odin run make.odin -file -- autopair-test
    -> all enabled/disabled autopair checks passed
odin run make.odin -file -- unicode-test
    -> all Unicode/fallback checks passed
odin run make.odin -file -- ligature-test
    -> enabled/disabled native ligature checks passed
odin run make.odin -file -- emoji-test
    -> all color-emoji checks passed
odin run make.odin -file -- test
    -> all 362 core unit tests passed, allocator tracking clean
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
```

Intermediate X11 runs corrected test coordinates and expected byte/view counts.
The typing suite also caught error-window focus stealing; the final shared
placement path leaves focus unchanged for errors, and directory plus typing
suites passed afterward. No native Windows/Wine run, real-desktop visual review,
asynchronous directory read, directory refresh command, or recursive traversal
was validated.

## Next task

M07.08 should add compatibility scenarios for window behavior, using the new
directory and error windows alongside shared buffers, editable tags, mouse
chords, and safe close/quit decisions.
