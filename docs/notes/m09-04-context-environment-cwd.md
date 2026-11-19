# M09.04 — Contextual environment and working directory

**Status:** done on Linux. Windows implementation and tests source-check with
pinned Odin `dev-2026-11`; Windows/Wine execution remains unvalidated.

## Snapshot contract

`src/core/process/context.odin` adds `Context_Description` and an owned
`Context_Snapshot`. Capture copies all caller inputs synchronously. A snapshot
owns its absolute working directory, environment slice, and every environment
entry, and remains independent of editor buffers, selections, and later parent
environment changes. `context_snapshot_destroy` releases all storage and is safe
on zero/partially initialized values.

Working-directory precedence is:

1. Explicit `working_dir`.
2. The normalized file's directory, or the file path itself for a directory buffer.
3. `project_root`.
4. The editor process's current working directory at capture time.

Paths are made absolute and lexically cleaned; capture does not resolve symlinks
or require project/instance roots to exist. A missing job working directory is
reported by the normal spawn failure path.

A nil base environment inherits a copy of the parent environment. A non-nil
base, including a non-nil zero-length slice, is exact. The snapshot replaces
reserved entries and appends the seven documented values in fixed order:

- `ACME_WINDOW_ID` and `ACME_BUFFER_ID` in decimal.
- `ACME_FILE`, `ACME_ADDRESS`, `ACME_PROJECT_ROOT`, and `ACME_INSTANCE_ROOT`.
- `ACME_ENDPOINT` as an opaque value, not a shell fragment.

Reserved-key replacement is case-sensitive on Linux and case-insensitive on
Windows. Other entries retain their order and values. No legacy Acme variables
or shell escaping/concatenation were added. Explicit malformed entries and the
existing 4096-entry/1 MiB budgets are enforced. Empty entries produced by the
pinned inherited-environment path are skipped because they carry no data;
explicit empty entries remain invalid.

## Job integration

`job_start_context` accepts a command argument array plus a borrowed snapshot.
`Job` now retains independent copies of the environment and working directory,
so callers may destroy the snapshot immediately after start. The existing direct
`Description` start API remains available and now has the same explicit
environment ownership and allocation-failure cleanup.

## Tests

The process suite now has 16 tests. New cases cover:

- Every documented variable, reserved replacement, and preserved custom values.
- Explicit/file/project/process cwd precedence and directory buffers.
- Exact non-nil empty environments and inherited-environment capture.
- Malformed and oversized input with partial-initialization cleanup.
- A real child launched from a snapshot destroyed immediately after start,
  verifying exact environment output and cwd plus retained job metadata.

## Validation

```text
odin run make.odin -file -- process-test
    -> 16/16 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all core unit tests passed, including process/context tests
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
odin check src/core/process -no-entry-point -vet -target:windows_amd64
odin check tests/unit/process -no-entry-point -vet -collection:hammer=src -target:windows_amd64
odin check tests/unit/process/helper -vet -target:windows_amd64
    -> product, context implementation, tests, and helper source checks passed
git diff --check
    -> passed
```

## Not validated and next task

Windows environment block construction and case-insensitive replacement were
source-checked but not executed natively. Editor invocation from `command.Source`
is intentionally deferred to M09.10; no external command routing was added here.

Next: M09.05 should consume ordered job output with bounded per-frame UI work,
transactional output-window updates, and explicit backpressure rather than
unbounded in-memory scrollback.
