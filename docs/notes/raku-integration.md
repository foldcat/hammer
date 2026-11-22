# Raku integration — design and decisions

**Status:** proposed on 2026-11-18; R-05 registry/discovery is implemented
by M09.09, invocation/context routing by M09.10, and the optional external regex
verb with native fallback by M09.11. Temp-file named filters, `-n`/`-p`, direct
one-liners, and the REPL are implemented by M09.12. Recorded because adding an optional external language
runtime and a user-defined command layer is an architecture change (AGENTS.md §1, scope §3:
"Do not introduce a … scripting runtime, plugin system, or major dependency
merely to complete a small task"), so it needs a documented decision before any
code.

**Scope of this note:** how an *optional* Raku binary (detected on `PATH`,
never embedded, no Raku-side app) integrates with hammer. The embedded-VM
route (MoarVM in-process) is explicitly rejected below and out of scope.

---

## 1. Non-negotiable line: the address language stays native

`M08.03` requires *compatible* regex semantics (spec §2.1, roadmap §18):
Acme/Plan 9 `regexp(7)` — leftmost, deterministic, non-backtracking, and
bounded. `/re/`, `?re?`, and `Edit` regexes therefore **always** use the
native Odin engine. They never fall back to Raku.

Rationale:

- **Compatibility.** Raku regexes are backtracking, grammar/property-based,
  and syntactically different (`token`/`rule`/`regex`, adverbs, `<rule>`).
  Substituting them would break the very semantics M08.03 exists to deliver.
- **Determinism.** The address language must behave identically whether or
  not Raku is installed. An environment-dependent engine in a
  compatibility-critical path is unacceptable.
- **Bounded/cancellable.** Backtracking can blow up exponentially, violating
  M08 acceptance ("long regex/edit operations are cancellable") and the
  bounded-work rule (AGENTS.md §3).

So "optional Raku regex, detect-then-use" does **not** apply to the address
language. It applies only to a *separate, explicitly invoked* facility (§4).

## 2. The optional external runtime is data, not code

`raku` is treated as one entry in a generic *named filter command* registry,
not as a special-cased subsystem. Once the async job service exists (M09),
Raku support is a config row plus a spawn path:

```text
name        engine   detect   program / args                  routing
sort-lines  raku     PATH     "$*IN.lines.sort.join(\"\\n\")"  replace-selection
sum-nums    raku     PATH     "say [+] $*IN.words"             output-window
check       raku     PATH     "-c <file>"                     output-window
repl        raku     PATH     (interactive)                   console
```

`engine` is generic (`raku | perl | awk | jq | sh | …`); Raku is the
first-class default because of its regex/text strengths. The editor builds a
*named external-filter command* layer, not a Raku command layer.

## 3. Decisions

| ID  | Decision                                                                                                      | Status   |
| --- | ------------------------------------------------------------------------------------------------------------- | -------- |
| R-01 | Address-language regex is always the native Odin engine; no Raku fallback.                                    | Proposed |
| R-02 | Optional Raku regex is a separate, explicitly invoked verb with native fallback (detect `raku` → use it, else native). | Implemented (M09.11) |
| R-03 | Commands are pure stdio filters: `(stdin + env + args) → stdout`. No editor API, no live object model.        | Implemented (M09.10) |
| R-04 | Editor state is passed as a one-shot invocation-time snapshot (env vars + stdin), never a live bidirectional handle. | Implemented (M09.10) |
| R-05 | Command *definitions* are declarative metadata + a body string; the registry is enumerable/validatable without executing anything. | Implemented (M09.09) |
| R-06 | Raku-driven editor *mutation* (move cursor, open window, rename, listen to events) is deferred to M18 IPC, versioned and revision-validated. | Proposed |
| R-07 | Raku is never embedded; absence is graceful (command unavailable or native fallback).                          | Implemented for external regex (M09.11) |

### 3.1 R-02/R-07 — optional external regex

The dedicated `Raku /pattern/` verb detects `raku` at invocation time. Present →
run the bounded asynchronous external adapter; absent → native engine. This is
the only place "detect-then-use-Raku-else-Odin" applies. See
`docs/notes/m09-11-external-regex.md` for the implemented contract.

### 3.2 R-03/R-04 — the state boundary (answers "pipe editor state to Raku?")

**Yes — as a snapshot.** Each invocation receives an immutable snapshot at
launch time: selection/file text on stdin, and small context in environment
variables (`HAM_FILE`, `HAM_DIR`, `HAM_DOT`/address, `HAM_WORD`,
`HAM_ARGS…`). The body can also read positional args via `@*ARGS`.

**No — not a live handle.** A command cannot call back into the editor
mid-run to read the *current* dot, mutate a buffer, open a window, or observe
events. That crosses into a plugin runtime (rejected, R-06) and forces every
command through stale-target/revision validation. A snapshot keeps the
boundary clean: one input in, one output out, one transaction.

### 3.3 R-05 — convenience without executing to discover

The convenience layer (what makes Raku commands feel built-in):

- **No shell quoting.** The program body is written to a temp file (or piped),
  run as `raku <file>`, so quoting/escaping is the editor's job, never the user's.
- **`-n` / `-p`.** Raku's line-processing flags make most filters one-liners.
- **Placeholder interpolation** (`$file`, `$sel`, `$word`, `$dir`, `$addr`) +
  positional args, expanded before run.
- **Declared routing:** `replace-selection` | `output-window` | `discard`;
  stderr always → output window.
- **Named, scoped, persistent:** per-user (`~/.config/hammer/`),
  per-project (`.hammer/`), session-only; `Cmd`/`Cmds` to list; tag completion.
- **Log echo before run** (the resolved invocation is logged; Raku does not open
  a redundant `+Errors` echo window).
- **Bounded:** every invocation rides M09's job service → `Stop`, cancellation,
  backpressure, and bounded output apply automatically.

Definitions are **metadata + body**, not executable Raku, precisely so the
editor can list and validate commands without running anything (trust rule:
don't `EVAL` a definition file merely to enumerate it). The only thing that
executes Raku is an explicit user invocation.

## 4. Guardrails (carried from trust/safety docs)

- Running a named command or an external regex = running code. It is explicit
  (tag/command invocation), never auto-run on file open, and log-echoed before
  run without a redundant `+Errors` window for Raku.
- Importing project `.hammer/` command definitions = importing executable
  project code; surface it rather than silently loading it.
- No silent lossy conversion; output is a byte string applied through the
  transaction engine like any other edit (AGENTS.md §3 "Transactions").
- A late pipe result cannot overwrite newer edits — inherits M09.07
  stale-target behavior.

## 5. Where this lands in the roadmap

Planned as M09.09–M09.12 (external-command features; they need M09's job
service). `docs/roadmap/m09.md` and `docs/specs/18-roadmap.md` §M09 carry the
tasks. `docs/roadmap/m08.md` records the R-01 invariant next to M08.03 so a
future session doesn't "helpfully" wire Raku into the address language.

## 6. Not validated

M09.09 implements and validates the registry, scopes, PATH detection, and
non-executing discovery on Linux/X11; M09.10 validates named-filter invocation;
M09.11 validates real Raku search and native fallback on Linux/X11. M09.12 adds
and validates direct `RakuEval` one-liners, temp-file named filters, `-n`/`-p`,
job-owned temp-file cleanup, and `RakuRepl`; see
`docs/notes/m09-12-raku-engine.md`. Direct evaluation and named filters use the
highlighted range as stdin, or the whole unsaved buffer at a collapsed caret.
Raku log echoes do not open `+Errors`. Windows remains source-checked only. The
current `.filter` format accepts single-line bodies, not multi-line programs or
PATHEXT customization. See `docs/notes/m09-09-filter-registry.md`,
`docs/notes/m09-10-command-invocation.md`, and
`docs/notes/m09-11-external-regex.md` for the earlier contracts.

Placeholder interpolation and multi-line `.filter` bodies remain unimplemented.
Native Windows/Raku execution, ConPTY REPL behavior, and interactive cancellation
of a pathological external regex remain unverified.
