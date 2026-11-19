# M08.07 — Atomic multi-buffer validation

**Status:** done on Linux. Windows source type-checking passes; native Windows
runtime was not exercised.

## Changes

`src/core/edit/runner.odin` adds `Result_Target` and `apply_results`. Each
target borrows its live document, selection, regex history, and worker result.
The application path validates every target's stable ID, generation, request
ID, and source revision before replaying any transaction. It also rejects nil
inputs and duplicate document pointers up front, and validates cancellation and
transaction-count limits across all targets before mutation.

Consequently, one stale target rejects the complete application without
changing any document, selection, undo log, or regex history. Once shared
validation succeeds, batches still replay through `txn.doc_apply` in target and
command order with their original undo grouping keys. Existing `apply_result`
is now a one-target wrapper, so the product's current single-buffer Edit path
uses the same validation logic.

This provides atomic stale-result validation, not general multi-document
rollback. Transaction application errors and Edit runtime errors retain the
existing successful-prefix behavior; previously applied transactions are not
rolled back. No current product Edit command spans buffers, so the multi-target
API is exercised by core unit tests rather than a new UI scenario.

Three tests in `tests/unit/edit/edit_test.odin` cover successful two-buffer
application, a stale generation on the second target, and a stale source
revision on the second target. Both stale cases prove the otherwise-valid first
buffer receives no edit or selection/history update.

## Validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin test tests/unit/edit -vet -collection:hammer=src
    -> 25/25 tests passed, allocator tracking clean
odin run make.odin -file -- test
    -> all 428 core unit tests passed, allocator tracking clean
odin check src -vet -collection:sokol=third_party/sokol/sokol
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> both source checks passed
odin run make.odin -file -- edit-test --no-config
    -> asynchronous Edit, save, move, substitution, and Undo X11 smoke passed
```

No native Windows/Wine runtime or product-level multi-buffer Edit scenario was
exercised. Allocation-failure rollback across separate documents is not added
or claimed; per-transaction atomicity remains provided by `txn.doc_apply`.

## Next task

M08.08 should add bounded, reproducible differential compatibility fixtures for
the supported address and Edit subset, recording any external Acme reference
requirements and reporting unsupported semantics explicitly.
