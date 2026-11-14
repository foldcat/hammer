# What is done?

Historical session entries are archived under
[`docs/archive/`](docs/archive/), one file per completed task, grouped by
milestone. This file is an index into that archive.

## Current task: M04.01 — Versioned checksummed journal

M03 is done (file loading, codecs, safe save, external changes, and save fault
injection). M04.01 is active: define bounded versioned journal records with
length, sequence, and checksum validation; replay only a verified prefix and
reject or contain torn/corrupt records without losing earlier valid entries.

## M00 — Specification, feasibility spikes, and build baseline

- M00.03 Build/run a window (Windows half) — [`m00/m00-03-windows-half.md`](docs/archive/m00/m00-03-windows-half.md)
- M00.08 Prove minimal FUSE/WinFsp adapter deployment — [`m00/m00-08-fuse.md`](docs/archive/m00/m00-08-fuse.md)
- M00.09 Record architecture decisions and compatibility inventory — [`m00/m00-09-decisions.md`](docs/archive/m00/m00-09-decisions.md)

## M01 — Application shell, platform layer, and compiled config

- M01.01 Implement lifecycle and error-reporting infrastructure — [`m01/m01-01-lifecycle.md`](docs/archive/m01/m01-01-lifecycle.md)
- M01.02 Add generated trusted configuration package — [`m01/m01-02-config.md`](docs/archive/m01/m01-02-config.md)
- Allocator migration (owner-directed arenas) — [`m01/m01-alloc-arenas.md`](docs/archive/m01/m01-alloc-arenas.md)
- M01.03 Create logical/physical coordinate conversion — [`m01/m01-03-coords.md`](docs/archive/m01/m01-03-coords.md)
- M01.04 Add native input normalization — [`m01/m01-04-input.md`](docs/archive/m01/m01-04-input.md)
- M01.05 Add worker/result queues with bounded capacity — [`m01/m01-05-queue.md`](docs/archive/m01/m01-05-queue.md)
- M01.06 Render basic column/tag/body rectangles — [`m01/m01-06-render.md`](docs/archive/m01/m01-06-render.md)

## M02 — Rope, transactions, anchors, and headless core

- M02.01 Implement immutable backing chunks — [`m02/m02-01-chunks.md`](docs/archive/m02/m02-01-chunks.md)
- M02.02 Implement leaves, metrics, and range iteration — [`m02/m02-02-leaves.md`](docs/archive/m02/m02-02-leaves.md)
- M02.03 Implement balancing and persistent root updates — [`m02/m02-03-tree.md`](docs/archive/m02/m02-03-tree.md)
- M02.04 Implement coordinate conversion — [`m02/m02-04-coords.md`](docs/archive/m02/m02-04-coords.md)
- M02.05 Implement transactions and revision tracking — [`m02/m02-05-transactions.md`](docs/archive/m02/m02-05-transactions.md)
- M02.06 Implement anchor transformation — [`m02/m02-06-anchors.md`](docs/archive/m02/m02-06-anchors.md)
- M02.07 Implement branching in-memory undo — [`m02/m02-07-undo.md`](docs/archive/m02/m02-07-undo.md)
- M02.08 Add randomized differential tests and benchmarks — [`m02/m02-08-benchmarks.md`](docs/archive/m02/m02-08-benchmarks.md)

## M03 — File loading, codecs, safe save, and external changes

- M03.01 Implement canonical file identity — [`m03/m03-01-fileid.md`](docs/archive/m03/m03-01-fileid.md)
- M03.02 Implement background chunked loading — [`m03/m03-02-fileload.md`](docs/archive/m03/m03-02-fileload.md)
- M03.03 Implement UTF-8/BOM/newline policy — [`m03/m03-03-filecodec.md`](docs/archive/m03/m03-03-filecodec.md)
- M03.04 Implement explicit unsupported/invalid encoding behavior — [`m03/m03-04-encoding-behavior.md`](docs/archive/m03/m03-04-encoding-behavior.md)
- M03.05 Implement temporary-write/replace save — [`m03/m03-05-filesave.md`](docs/archive/m03/m03-05-filesave.md)
- M03.06 Implement disk-change conflict detection — [`m03/m03-06-filestate.md`](docs/archive/m03/m03-06-filestate.md)
- M03.07 Add failure-injection tests for save — [`m03/m03-07-save-faults.md`](docs/archive/m03/m03-07-save-faults.md)

## Misc

- Build tool fix (live `run` output) — [`misc/build-tool-fix.md`](docs/archive/misc/build-tool-fix.md)
