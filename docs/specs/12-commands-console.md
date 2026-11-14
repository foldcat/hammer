# 12. Asynchronous commands and modern console support

## 12.1 Job model

States:

```text
Queued
Starting
Running
CancelRequested
Exited
FailedToStart
```

Each job records:

- Command.
- Shell/backend.
- Working directory.
- Environment.
- Source window/buffer.
- Selection snapshot.
- Output destination.
- Exit status.
- Start/end time.
- Cancellation support.

## 12.2 Process spawning

### Unix

- Spawn without blocking the UI.
- Separate stdin/stdout/stderr pipes.
- Process group for cancellation.
- PTY for interactive sessions.

### Windows

- Correct argument quoting.
- Explicit inherited handles.
- Pipes for noninteractive jobs.
- Job Objects where appropriate for lifecycle management.
- ConPTY for interactive sessions.

Do not construct a command line by concatenating unescaped file paths.

Distinguish:

- Direct executable invocation with argument arrays.
- Explicit shell command execution.

Shell choice should be configurable.

## 12.3 Acme command context

External jobs need context such as:

```text
ACME_WINDOW_ID
ACME_BUFFER_ID
ACME_FILE
ACME_ADDRESS
ACME_PROJECT_ROOT
ACME_INSTANCE_ROOT
ACME_ENDPOINT
```

Add legacy environment-variable compatibility only after verifying the exact reference semantics.

## 12.4 Selection pipes

Support the documented Acme meanings of:

```text
>command
<command
|command
```

Typically these correspond to feeding selected text to a process, replacing from process output, and piping selected text through a process—but use the compatibility specification for exact details.

### Asynchronous replacement rule

When a command starts:

1. Capture the source selection and revision.
2. Provide a snapshot to stdin.
3. Collect output asynchronously.
4. Validate the target range before replacing.

If the user edits that range while the command runs:

- Do not overwrite the new work.
- Preserve command output in an output window.
- Offer explicit application/replacement.

Successful replacement is one undo transaction.

## 12.5 Two console models

Do not conflate these.

### A. Acme-style command/log window

An editable text buffer containing command output.

Supports:

- Unicode.
- ANSI styles.
- Colored diagnostics.
- Progress lines.
- Clickable file locations.
- Acme selection, execution, and lookup.

This should be the default.

### B. Terminal window

A terminal grid attached to PTY/ConPTY.

Supports:

- Terminal cursor addressing.
- Alternate screen.
- Raw input.
- Terminal resizing.
- Full-screen programs if the advertised emulation supports them.

This is a separate view kind.

A full terminal cannot be represented faithfully as an ordinary editable log buffer.

## 12.6 ANSI parser

Use a streaming state machine.

It must preserve state across output chunks.

Minimum log-window support:

- UTF-8 decoding across chunk boundaries.
- SGR reset.
- Basic and bright colors.
- 256-color palette.
- True color.
- Bold/dim/italic/underline where supported.
- Carriage-return progress updates.
- Backspace.
- Erase-to-end-of-line.
- Safe OSC handling.
- Hyperlinks if deliberately supported.

Unknown sequences must be handled deterministically.

Do not execute control strings.

In particular:

- OSC clipboard writes should be disabled by default or require explicit permission.
- Hyperlinks must not automatically execute shell commands.
- Output text that looks like a command is not automatically executed.

## 12.7 Output storage

Store styles separately from text.

For long-running jobs:

- Batch updates.
- Keep the UI mutation budget bounded.
- Maintain bounded in-memory scrollback.
- Spill older output to disk when appropriate.
- Preserve ordered stream records.

Separate stdout/stderr pipes do not provide a perfect global ordering. Do not claim one unless using a transport that actually provides it.
