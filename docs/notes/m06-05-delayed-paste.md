# M06.05 — Delayed-paste target validation

**Status:** done as a backend-free, transaction-backed pending-paste path. Linux
headless tests and product smoke passed; the editing package type-checks for
Windows. Product event dispatch still has no editable document consumer, so this
task does not claim an end-to-end desktop paste.

## Target capture and completion

`src/core/editing/paste.odin` adds a view-owned `Delayed_Paste` value and a
captured `Paste_Target`. `delayed_paste_begin` records:

- nonzero stable buffer and request IDs;
- buffer generation and source revision;
- independent `txn.Anchor` values for the selection's anchor and active end;
- selection affinity.

One instance permits one pending request. Beginning validates the current
selection without retaining document, selection, or payload pointers. The caller
starts the native clipboard read only after capture succeeds.

`delayed_paste_apply` requires the result request ID and looked-up buffer ID and
generation to match. It never consults the currently focused window or uses its
selection as a fallback. The captured anchors transform through intervening
edits on the current history path; an abandoned source revision is rejected as a
conflict. Invalid UTF-8, unavailable targets, invalid transformed selections, and
transaction failures do not change text or the live selection.

A matching result is consumed exactly once, whether applying succeeds or fails,
so duplicate and late results are rejected. Identity mismatches leave the
request pending for its actual result. `delayed_paste_cancel` consumes a matching
pending request; the caller also cancels native I/O, and any already queued
result remains harmless. Target destruction uses this cancellation path.

Accepted text replaces the captured range through one `txn.doc_apply` transaction
with source `.Paste`, current base revision, and a collapsed post-paste caret.
The payload is borrowed only during the call; the transaction log owns its copy.
The pending value itself owns no allocations and needs no destructor.

## Tests

Six editing tests cover:

- Unicode replacement of the captured directional selection after selection and
  focus changes, without touching another document;
- anchor transformation through an intervening edit;
- wrong buffer, generation, and request IDs, plus duplicate completion;
- cancellation and rejection of a late result directed at another document;
- rejection of an abandoned source revision after undo and a sibling edit;
- invalid captures, invalid UTF-8, unavailable targets, and state preservation.

## Validation

```text
odin test tests/unit/editing -vet -collection:hammer=src
    -> 18/18 passed, allocator tracking clean
odin check src/core/editing -no-entry-point -vet -target:windows_amd64
    -> Windows-target type check passed; no Windows runtime test
odin run make.odin -file -- test
    -> all 288 core unit tests passed
odin run make.odin -file -- build
    -> Linux debug product build passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= ./build/hammer
    -> ten-frame lifecycle smoke passed
```

## Limits and next task

- Native clipboard requests and results were not exercised end to end with this
  state; M06.04 separately validated the platform services, and M06.08 owns
  interoperability coverage.
- No real Windows runtime test or real desktop focus-change scenario was run.
- Product buffer/view lookup must call cancellation when a captured target is
  destroyed and must report native/apply errors when product dispatch is wired.
- M06.06 should implement multiline indent/outdent as one transaction, preserving
  selection direction and adjusting its anchors.
