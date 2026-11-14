# 22. Testing strategy

A project like this needs more than unit tests.

## 22.1 Unit tests

- Command parsing.
- Address parsing.
- Metrics.
- Anchor transformation.
- EditorConfig resolution.
- ANSI parser state transitions.
- Protocol framing.
- Undo branch navigation.

## 22.2 Property tests

- Rope versus reference model.
- Edit/undo round trips.
- Coordinate conversions.
- Transaction range validation.
- Journal replay.
- Randomized ANSI chunk boundaries.

## 22.3 Integration tests

- Open/edit/save/reopen.
- Shared-buffer windows.
- Async command replacement.
- IPC mutations.
- Filesystem reads/writes.
- Project restoration.
- Git status parsing.

## 22.4 Platform tests

- Clipboard interoperability.
- Large clipboard transfers.
- IME.
- DPI.
- File replacement.
- Unicode filenames.
- Process cancellation.
- PTY/ConPTY.
- Named-pipe ACLs.
- FUSE/WinFsp shutdown.

## 22.5 Crash tests

Inject failure:

- Before journal write.
- During journal write.
- Before flush.
- During checkpoint rotation.
- During save.
- After temporary save but before replace.
- During layout save.
- During process output spill.

Verify recovery from every complete durable prefix.

## 22.6 Compatibility tests

Use a corpus of interaction and command scenarios from the pinned Acme implementation.

Compare:

- Resulting text.
- Selections.
- Window lifecycle.
- Address evaluation.
- Command behavior.
- Event handling.

Visual modernization can differ. Semantic differences must be explicit.

## 22.7 Visual tests

Fixtures for:

- Tag/body colors.
- Syntax/selection interaction.
- Mixed scripts.
- Fallback fonts.
- Fractional DPI.
- RTL/bidi controls.
- Long lines.
- Git markers.
- Completion popup.
- Undo tree.

GPU screenshot tests may need tolerances; core geometry tests should remain deterministic.
