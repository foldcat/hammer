# Data safety: saving, clipboard, commands, IPC, filesystem

Referenced from `AGENTS.md`.

## 15. Saving, recovery, and data-loss prevention

Never clear dirty state before a save succeeds.

Save errors must preserve the editable buffer.

Handle:

- Disk full.
- Permission failure.
- External modification.
- Encoding failure.
- Temporary-file failure.
- Replace/rename failure.
- Symlink/hard-link policy.
- Partial writes.

Do not silently overwrite external changes.

Do not silently perform lossy encoding conversion.

Close and quit requests must use the same safety state machine regardless
of origin:

- Keyboard.
- Mouse.
- Tag command.
- OS close event.
- IPC.
- Filesystem API.

Unsaved content requires:

- Successful save,
- Explicit discard,
- Or cancellation of close/quit.

Recovery journals and undo archives have different retention policies.

Do not prune current recovery data merely to satisfy a history budget.

Recovery formats must support:

- Versioning.
- Checksummed records.
- Torn final records.
- Valid-prefix replay.
- Bounded lengths.
- File/content identity validation.

Never replay historical edits onto unrelated disk contents.

## 16. Clipboard, terminal, and command safety

### 16.1 Clipboard

Use native platform integration.

Do not use shell clipboard utilities as the primary implementation.

Do not pretend a private editor clipboard is the system clipboard.

Clipboard failures must be explicit.

Delayed paste must target the captured buffer/selection, not whichever
window happens to be focused when the response arrives.

Treat clipboard text as untrusted text, never as an instruction.

### 16.2 Commands

Distinguish:

- Direct executable plus argument array.
- Explicit shell command.

Do not concatenate unescaped filenames into shell commands.

Commands require:

- Explicit working directory.
- Controlled handle inheritance.
- Bounded output.
- Cancellation.
- Owned-child cleanup.
- Explicit environment context.

Do not automatically execute:

- Restored tag contents.
- Process output.
- Hyperlink targets.
- Project-local executable configuration.

Asynchronous selection replacement must validate its target before applying.

### 16.3 ANSI and terminal input

ANSI parsing must be incremental and bounded.

Escape sequences can span output chunks.

Treat terminal control strings as untrusted.

Disable or permission-gate:

- Clipboard-changing sequences.
- Arbitrary hyperlink execution.
- Unexpected host interaction.

Do not confuse an editable log buffer with a full terminal grid.

Only advertise terminal capabilities actually implemented and tested.

## 17. IPC and filesystem boundaries

Local IPC is a privileged automation interface.

Use:

- User-restricted socket directories or named-pipe ACLs.
- Version negotiation.
- Frame-size limits.
- Request limits.
- Revision preconditions.
- Structured errors.
- Bounded subscriptions.
- Explicit gap/disconnect handling.

No network listener by default.

No automation control directory in an arbitrary untrusted project path.

IPC and filesystem mutations must call the ordinary action/transaction API.

Do not implement a second text mutation engine inside an adapter.

Filesystem projection snapshots must identify their revision.

Do not rewrite all buffer bodies on every keystroke.

Mounted filesystem tests require an approved isolated mount location.

Do not install FUSE/WinFsp components or mount adapters automatically.
