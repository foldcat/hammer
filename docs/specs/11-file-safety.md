# 11. File safety, recovery, and shutdown

This is infrastructure, not a finishing feature.

Implement it before encouraging users to edit important files.

## 11.1 Safe save

Recommended flow:

1. Capture immutable buffer snapshot.
2. Validate current disk identity/state.
3. Encode/format according to explicit save policy.
4. Write a temporary file in the same filesystem/directory when possible.
5. Flush as configured.
6. Atomically replace using the appropriate platform mechanism.
7. Preserve relevant permissions/metadata.
8. Record the saved checkpoint only after success.

Define policies for:

- Symlinks.
- Read-only files.
- Permission changes.
- Files modified externally.
- Hard links.
- Encoding failure.
- Disk-full errors.
- Rename/replace failures.

No save error should clear the dirty indicator.

## 11.2 External modification

When a file changes externally:

### Buffer clean

Offer or perform a safe reload according to configuration.

### Buffer dirty

Show a conflict state.

Offer:

```text
Reload and discard local changes
Keep local buffer
Save to another path
Compare
Explicit overwrite
```

Never silently overwrite an external change.

## 11.3 Swap/recovery storage

Suggested structure:

```text
state/
  recovery/
    <buffer-or-file-key>/
      manifest.json
      checkpoint.bin
      journal-000001.bin
      journal-000002.bin
```

Include:

- Format version.
- File identity/path.
- Base content hash.
- Encoding metadata.
- Session ID.
- Process-instance identity.
- Sequence numbers.
- Checksums.
- Timestamps.

Do not rely on PID alone for stale-lock detection.

## 11.4 Journal format

Append transaction records.

Each record should have:

```text
length
version
sequence
transaction payload
checksum
```

Recovery reads valid records until the last complete verified record.

A torn final record must not destroy the earlier journal.

## 11.5 Durability policy

Be honest about the difference between:

- Edit visible in memory.
- Edit queued for persistence.
- Edit durably flushed.

Recommended default:

- Frequent batched journaling.
- A configurable durability interval.
- Synchronous flush before clean shutdown.
- An optional strict mode that prioritizes durability over latency.

Do not promise zero loss during power failure unless the implementation’s acknowledgment and flush policy actually provides it.

## 11.6 Shutdown state machine

```text
Running
 -> QuitRequested
 -> InspectDirtyBuffersAndJobs
 -> AwaitDecision
 -> SaveOrDiscard
 -> FlushPersistentState
 -> StopServices
 -> Exit
```

Offer:

```text
Save All and Exit
Review Unsaved
Discard Explicitly and Exit
Cancel
```

Requirements:

- Save failure blocks exit.
- A canceled Save As blocks exit.
- Untitled buffers containing user work are included.
- Closing the last view of a dirty buffer triggers the same protection.
- Closing one of several views does not necessarily destroy the buffer.
- IPC and filesystem-driven close requests use the same protection.
- Running jobs are handled separately from dirty buffers.

For running jobs:

```text
Wait
Cancel jobs
Detach, only when supported
Cancel exit
```

An OS kill or power loss cannot always be prevented; recovery is the fallback.

## 11.7 Persistent undo storage

Persistent undo and crash recovery are related but different:

- **Recovery journal:** protect current unsaved work.
- **Undo archive:** preserve historical branches.

Use shared serialization infrastructure, but different retention policies.

Never prune recovery data merely because a history budget was exceeded.
