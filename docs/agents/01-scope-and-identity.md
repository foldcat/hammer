# Scope and identity

Referenced from `AGENTS.md`.

## 3. Product identity

This is an Acme reimagining, not a conventional IDE with an Acme theme.

Preserve:

- Editable tags.
- Columns and windows.
- Select / execute / look.
- Supported original mouse chording.
- Text-oriented command execution.
- Multiple views of the same buffer.
- Acme addressing and required Edit semantics.
- External programmability.
- First-class filesystem access.

Modernize:

- Native system clipboard.
- Unicode, font shaping, fallback, and DPI.
- Touchpad and keyboard accessibility.
- Asynchronous command execution.
- Safe saving and shutdown.
- Recovery and persistent branching undo.
- Tree-sitter highlighting.
- Lightweight completion, finder, and Git support.
- Versioned local IPC.

Do not introduce a new UI framework, scripting runtime, plugin system,
or major dependency merely to complete a small task.

Architecture changes require a documented decision.

You may take a look at `/home/user/Builds/p9p`, which contains the
plan9 port source code. Use it for reference only. Do not port it
line by line into Odin as this is a reimagination, not a recode.

## 5. Work selection and scope

One session should normally complete one small vertical slice.

Good:

- Implement native clipboard retrieval with explicit ownership and tests.
- Add rope range deletion and differential property tests.
- Reject stale asynchronous selection replacement.

Bad:

- Implement the entire editor.
- Add several unrelated features.
- Create empty interfaces and call the feature complete.
- Reorganize the repository while fixing a small bug.

Allowed changes:

- The requested behavior.
- Tests for that behavior.
- Direct prerequisite fixes.
- Relevant documentation.
- Necessary build integration.

Avoid:

- Unrelated formatting.
- Mass renaming.
- Speculative abstractions.
- Dependency upgrades unrelated to the task.
- Replacing existing working subsystems.
- Removing requirements to make acceptance easier.

If a prerequisite is larger than the current task:

- Stop and describe it.
- Update the task plan.
- Do not conceal the expanded scope.
