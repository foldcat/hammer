## M03.06 done (2026-11-14 session)

Disk-change conflict detection (`docs/notes/m03-06-filestate.md`) — a
backend-free `src/core/filestate` observation and decision layer:

- Handle-based polling classifies Unchanged, Modified, Replaced, and Missing.
  Capture errors never become false unchanged results. Clean changes offer
  reload; dirty changes expose Reload/Discard, Keep, Save As, Compare, and
  Explicit Overwrite. Missing dirty files offer Keep/Save As without claiming
  reload or in-place overwrite.
- `identity_verified` explicitly exposes `.None`-identity degradation.
  filesave's normal `.Unchanged` policy now rejects unverified identities;
  explicit `allow_unverified_identity` compares only size/mtime, while verified
  checkpoints still require exact identity/version equality.
- Six filestate tests plus a new filesave regression cover real modification,
  atomic replacement, deletion, policy/actions, errors, and degraded identity.
  Validated 6/6 leak-free ×10 and single-threaded, 14/14 filesave, full suite
  183 tests, debug/release builds, Xvfb smoke, and a Windows `-no-crt` consumer
  under Wine covering all four observation classes.
- No automatic reload, buffer mutation, OS watcher, or UI is claimed. Real
  Windows, canonical-path/case probing, and same-metadata edits remain outside
  validated detection; M03.07 owns injected save failures.
