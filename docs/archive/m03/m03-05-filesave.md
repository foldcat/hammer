## M03.05 done (2026-11-14 session)

Temporary-write/replace save (`docs/notes/m03-05-filesave.md`) — a backend-free
`src/core/filesave` snapshot save adapter:

- Streams an immutable rope root into a same-directory temporary file without
  flattening, preserving UTF-8 BOM/newline bytes and existing permissions.
  Default fsync precedes publication. Only the mutation owner may later apply
  the returned revision/checkpoint to dirty state.
- Explicit `.Must_Not_Exist`, `.Unchanged`, and `.Allow_External_Changes`
  policies; no-clobber hard-link publication for new files and atomic rename
  replacement for existing files. Follows bounded symlink chains without
  replacing links; rejects Preserve_Link saves through links, read-only files,
  and hard-link breakage unless deliberately allowed.
- Returns a fresh handle-based checkpoint only after success. Post-publication
  errors carry `replaced=true`; all earlier errors leave the destination
  untouched and clean up the temporary file. No document or dirty state is
  mutated by the package.
- 13 tests cover old-root immutability, BOM/mixed-newline reopen, checkpoint
  conflicts/reuse, overwrite, no-clobber, symlinks, permissions, hard links,
  empty saves, and real failures. Validated 13/13 leak-free ×10 and
  single-threaded, full suite 176 tests, debug/release builds, Xvfb smoke, and
  a Windows `-no-crt` save/reload/conflict consumer under Wine.
- Limits recorded in the session note: directory-entry sync, ownership/ACL
  preservation, real-Windows validation, and M03.07 injected I/O faults are not
  claimed; stamp checks remain best effort against identical-metadata and
  final-rename races.
