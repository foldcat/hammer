# M03.05 — Temporary-write/replace save

Session doc for `src/core/filesave` (2026-11-14): synchronous, snapshot-based
safe save over the M02 immutable rope and M03 file identity/codec metadata
(SPECS.md §7.4 and §11.1).

## Design

```text
Snapshot       borrowed rope.Tree + immutable root + revision
Options        Disk_Check + expected Capture + symlink/read-only/hard-link/
               flush policies
Result         saved revision + post-save Capture + replaced flag
save_tree      validate -> resolve -> temp -> stream -> sync -> permissions
               -> recheck -> publish -> capture
```

- **Immutable streaming.** `save_tree` reads a captured rope root span by span;
  later tree edits cannot change the saved content. It never flattens the
  snapshot. Only UTF-8 metadata with no BOM or a UTF-8 BOM is accepted. Content
  and LF/CRLF/CR bytes are preserved exactly; escaped display text and
  unsupported original encodings are not save inputs.
- **Disk policy.** `.Must_Not_Exist` is the safe zero value for Save As.
  `.Unchanged` requires the expected identity/size/mtime both before writing and
  immediately before publication. `.Allow_External_Changes` is the deliberate
  overwrite escape hatch. New-file publication uses a hard link plus temporary
  link cleanup, giving atomic no-clobber behavior even if another process wins
  the race. Existing files use same-directory rename/MoveFileEx replacement.
- **Path and metadata policy.** `.Follow` resolves at most 40 symlinks and
  replaces the final target, preserving the link. `.Preserve_Link` refuses a
  symlink rather than replacing it. Read-only files are rejected unless
  explicitly allowed. Existing permission bits/read-only state are applied to
  the temporary file before publication. Replacing a multiply linked file is
  rejected unless hard-link breakage is explicitly allowed; the other links
  then retain the old inode/content.
- **Flush and checkpoint.** The default `.Sync` calls fsync/FlushFileBuffers on
  the complete temporary file before publication; `.None` is explicit. A fresh
  handle-based `Capture` is obtained only after publication. `Result.revision`
  identifies the snapshot. No buffer root, dirty flag, or saved checkpoint is
  mutated here: the single mutation owner must apply a result only if its
  revision still matches. No error clears dirty state.
- **Post-publication errors.** `Result.replaced=true` distinguishes a published
  destination from every pre-publication failure. If temporary-link cleanup or
  checkpoint capture fails after publication, the returned error is accompanied
  by `replaced=true`; callers must not blindly retry as though nothing changed.
  Temporary files are otherwise closed and removed on failure.
- **Ownership and bounds.** Paths, error messages, and temporary-file names use
  the caller allocator; Target cleanup releases stat strings and paths. Rope
  spans are borrowed only for the synchronous call. Temp-name retries and
  symlink traversal are bounded; writes stream proportional to the snapshot
  with no whole-file allocation. No background worker or cancellation API is
  introduced in this slice.

## Validation run

```text
odin check src/core/filesave -no-entry-point -vet          -> clean
odin check src/core/filesave -no-entry-point -vet -target:windows_amd64
                                                            -> clean
odin test tests/unit/filesave -vet -collection:hammer=src  -> 13/13,
    leak-free (memory tracking enabled)
same targeted command, 10-run loop                         -> 13/13 each
same targeted command -define:ODIN_TEST_THREADS=1          -> 13/13
odin run make.odin -file -- test                           -> 16 packages,
    176 tests, exit 0, leak-free
odin run make.odin -file -- build                          -> exit 0
odin run make.odin -file -- build --release                -> exit 0
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
                                                            -> exit 0,
    clean lifecycle shutdown
Windows -no-crt consumer (build/m03-05-consumer, generated)
    cross-built for windows_amd64 with the repository SDK/lld flags and run
    under Wine: new save, checkpointed replacement, reload/checkpoint match,
    and stale-checkpoint rejection — "filesave M03.05 consumer: ok", exit 0
```

The 13 tests cover immutable old-root save after later edits; UTF-8 BOM and
mixed-newline byte-exact reopen; permission preservation and checkpoint reuse;
stale conflict without disk/temp changes; explicit overwrite; Save As
no-clobber; relative symlink following and Preserve_Link rejection; bounded
symlink cycles; read-only rejection/override; hard-link rejection/explicit
break; non-UTF-8 policy rejection before creation; missing-parent failure; and
empty snapshot replacement with flushing disabled.

## Traps found

1. **`os.get_absolute_path` is not lexical on Linux**: it resolves through
   realpath, fails for a not-yet-created file, and resolves symlinks before the
   save policy can inspect them. filesave now joins relative paths to getwd and
   uses `os.clean_path`, leaving symlink resolution to its bounded lstat loop.
2. **Windows ordinary-file `lstat` lacks handle identity**: its
   GetFileAttributesEx fast path has no volume serial/file index. Initial and
   final checkpoints therefore always use `fileload.capture_file` (handle-based
   fstat), not identity fields from a path `File_Info`.
3. **Pinned syntax/API details**: Odin uses `name: Type`, not `var name Type`;
   slice procedure parameters are immutable unless copied locally; a zero write
   is mapped to `os.General_Error.Invalid_File`; Linux statx mode is a bit set
   and requires an explicit transmute before masking permission bits.
4. **Defers are LIFO and block-scoped**: removal must be registered before the
   close defer so close executes first on failure. The opposite order attempts
   to unlink an open temporary file on Windows and can leave it behind.

## Platform status and limits

- **Linux:** implemented and tested in unique filesystem sandboxes, including
  symlink/hard-link/permission behavior, full core suite, builds, and smoke.
- **Windows:** implemented and tested under Wine with a `-no-crt` consumer.
  Real Windows, ACL preservation, and rename semantics on real NTFS/ReFS remain
  unvalidated. Only permission/read-only state is preserved; ownership, ACLs,
  and other extended metadata are not copied.
- **Durability:** file contents are synced by default, but parent-directory
  entries are not synced after publication. This is not a claim of zero data
  loss after power failure.
- **Conflict race:** identity/size/mtime checks are best effort. A change with
  identical size/mtime is undetectable, and an external rename can still race
  the final check and replacement; portable conditional atomic replace is not
  provided by these OS APIs. M03.06 owns user-facing conflict detection.
- **Failure injection:** disk-full, short-write, flush, close, and injected
  rename faults remain M03.07; this slice tests real policy and path failures.

## Next task

M03.06 — disk-change conflict detection: compare fresh handle-based captures
with the load/save checkpoint, classify clean versus dirty-buffer behavior, and
preserve the explicit-overwrite decision without weakening M03.05 save policy.
