# Acme compatibility contract

This is the current product compatibility record for the behavior required by
`docs/specs/02-acme-contract.md`. "Tested" below means the named behavior has
automated coverage on Linux/X11; it is not a native Windows validation claim.
The pinned Plan 9 User Space for Porting source is the reference for detailed
Acme behavior, not an implementation to copy mechanically.

## Preserved behavior

- Columns contain independently sized windows. Window and column controls
  support dragging, moving, resizing, and reordering. Covered by `layout-test`.
- Buffers and views are separate. Ordinary windows own independent buffers;
  views have independent selections and viewport state. The core supports
  multiple views of one buffer, although no product Zerox command exists yet.
- Global, column, and window tags are editable. Window tags regenerate `Put`
  for dirty file buffers without overwriting the user's command suffix.
  Covered by `tag-test`.
- Button 1 selects, button 2 executes supported text commands, and button 3
  looks up files, directories, or literal text. Supported selection expansion,
  modifier alternatives, and mouse chords use the shared mouse state machine.
  Covered by `mouse-test` and `look-test`.
- Directory windows present sorted, three-lane listings, mark subdirectories,
  and resolve nested Look paths relative to the listing. Covered by
  `directory-test` and the directory unit tests.
- Each view has a configurable soft-wrap or truncate mode. Soft wrapping shares
  grapheme-safe visual rows between rendering and hit-testing; truncate views
  support horizontal wheel/touchpad scrolling. Covered by `wrap-test`.
- Recoverable editor errors accumulate in a reusable `+Errors` window without
  taking focus. Automatic output uses transactions and cannot silently clean a
  user-edited error buffer.
- `Del`, `Put`, `Undo`, `Redo`, `Look`, and the implemented clipboard commands
  operate through their ordinary editor paths. The integrated
  `compatibility-test` exercises these behaviors together rather than treating
  each window feature as an isolated callback.

## Intentional modernization

- Startup opens the requested file or an untitled buffer on the left and the
  process working directory as an explorer on the right.
- Native system clipboard integration replaces a private-only clipboard.
  Clipboard results retain their originating view and buffer identity.
- Keyboard and modifier-assisted alternatives supplement mouse-only actions.
- Dirty named, untitled, directory, and error buffers use the same close/quit
  guard. Unsaved user edits require a successful save, explicit discard, or
  cancellation; automatic error output never bypasses that rule.
- Errors are both logged and displayed in `+Errors`. Error-window creation does
  not interrupt work by changing the active document.

## Unsupported or deferred behavior

- The complete internal command registry, Acme Edit/address language, external
  command execution, and asynchronous command output belong to M08/M09.
  Directory `Get`, `New`, `Newcol`, `Zerox`, and the other unregistered commands
  are not claimed as working merely because their names are recognized or
  visible in tags.
- A product command for multiple views of one buffer (Zerox) is deferred; only
  the underlying core view model and tests currently exist.
- Vertical viewport scrolling, scrollbar interaction, and line-number gutters
  remain later M07 tasks.
- Persistent layout restoration, filesystem projection, local IPC automation,
  and external event interception are later milestones.
- Native Windows behavior is source-checked but not runtime-tested here.
