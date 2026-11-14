## M03.07 done (2026-11-14 session)

Failure-injection tests for save (`docs/notes/m03-07-save-faults.md`):

- Optional borrowed `filesave.Operation_Hooks` wrap temp creation, writes, sync,
  chmod, close, remove, link/rename, and capture; nil fields preserve real OS
  behavior and no global/test-only state is introduced.
- Six new tests (20 filesave total) cover nine pre-publication fault classes,
  one-byte partial writes, new-file link failure, and post-publication capture /
  cleanup errors. Pre-publication faults preserve the original, return no
  checkpoint, and clean temporary files; post-publication faults preserve new
  content and report `replaced=true`.
- Validated 20/20 leak-free ×20 and single-threaded; full suite 189 tests;
  debug/release builds; Xvfb smoke; Windows `-no-crt` consumer under Wine for
  write/rename/final-capture faults and cleanup.
- Tests inject errors in isolated sandboxes rather than filling a disk. Process
  kill, power-loss durability, directory sync, and recovery from journal tears
  are not claimed; M04 owns recovery journaling and crash testing.
