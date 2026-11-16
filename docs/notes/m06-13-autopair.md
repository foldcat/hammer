# M06.13 — Configurable autopair policy

**Status:** done on Linux/X11 with real enabled/disabled product validation.
Windows-target editing and config core checks pass. The full Windows product
build remains blocked before source compilation by the existing build flag.

## Configuration

The compiled YAML key is:

```yaml
autopair: true
```

It defaults to true when omitted. `autopair: false` disables every autopair
behavior and preserves literal typing and ordinary Backspace. `Config.Autopair`
uses `Maybe(bool)` to distinguish omission from an explicit false; `Resolved`
and generated source carry a plain boolean. The generated schema version is 3,
and configuration diagnostics include the effective value.

`configs/example.yaml` documents the switch. No runtime configuration loading or
new dependency was introduced.

## Editing policy

`src/core/editing/autopair.odin` recognizes `()`, `[]`, `{}`, double and single
quotes, and backticks.

- A collapsed opening delimiter inserts both bytes and leaves the caret inside,
  except when a bracket-like opener can reuse an unmatched corresponding closer.
- Bracket closer reuse follows the default `ultimate-autopair.nvim` start-pair
  algorithm: compute unmatched opener depth before the caret, add the proposed
  opener, then scan forward in byte order until a closer reduces depth to zero.
  Only the opening byte is inserted when such a closer exists. A closer already
  matched by an earlier opener does not suppress the new pair.
- Bracket matching is multiline over a centered window of at most 1000 lines.
  Quote pairs remain line-local, matching the plugin's default pair settings.
- A nonempty selection is always wrapped with two original-snapshot insertions in
  one transaction. The selected text remains selected and its direction is preserved.
- A collapsed closing delimiter or quote matching the byte at the caret moves
  over it without changing the revision or history.
- Backspace between an empty pair deletes both bytes in one transaction.
- Non-delimiters, nonmatching closers, and multi-scalar IME commits use ordinary
  editing. Single-scalar commits share the pair policy because X11 delivers normal
  printable input through its commit path.

References: the plugin's [default configuration and pairing rules](https://raw.githubusercontent.com/altermo/ultimate-autopair.nvim/v0.6/doc/ultimate-autopair.txt)
and [pair-counting implementation](https://raw.githubusercontent.com/altermo/ultimate-autopair.nvim/v0.6/lua/ultimate-autopair/profile/default/utils/open_pair.lua).
Hammer mirrors its balanced start-pair behavior, not its syntax-tree filters or
language-specific extensions.

`src/core/editing/editing.odin` retains `perform` as the literal backend-free API
and adds `perform_with_options`. `src/editor.odin` passes `cfg.Autopair` through
`Input_Options`; the editing core does not import the config package.

Adjacent pair probes use fixed one- or two-byte rope reads. Multiline balancing
walks bounded rope spans and never flattens the document. Selection wrapping does
not copy selected text. Insert/delete data is stack-borrowed only during
`doc_apply`, which owns the logged copies. Newline inheritance and other text
operations share the generalized typing-transaction helper without changing their
behavior.

## Regression coverage

`tests/unit/editing/autopair_test.odin` covers all six delimiter pairs, close
skipping, empty-pair deletion and undo, reverse-selection wrapping and redo,
nonadjacent closers, disabled literal behavior, and single- versus multi-scalar
commits. Multiline cases cover all three bracket pairs, the plugin's balance
examples, byte-order-sensitive matching, the 1000-line limit, and line-local
quotes. Config tests cover default true, explicit true/false, malformed values,
and generated false output.

`make.odin -- autopair-test` builds two products from isolated configs under
`build/` and runs `tests/integration/autopair/x11_harness.py`. The harness uses
separate X11 clipboard reads to verify empty-pair Backspace, multiline closer
reuse, selection wrapping, quotes, and disabled literal behavior in the real
product. It restores built-in staging afterward and cleans up its owned processes
and sandbox on success.

## Validation

Using pinned Odin `dev-2026-11`:

```text
odin test tests/unit/config -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 18 config tests passed, allocator tracking clean
odin test tests/unit/editing -vet -collection:hammer=/home/user/Projects/hammer/src -define:ODIN_TEST_THREADS=1
    -> all 43 editing tests passed, allocator tracking clean
odin run make.odin -file -- autopair-test
    -> enabled and disabled Linux product builds and all exact-byte X11 checks passed
    -> multiline `(a\n)` reuse check passed in the real product
odin run make.odin -file -- test
    -> all 319 core unit tests passed, allocator tracking clean
odin run make.odin -file -- typing-test
    -> existing Linux product typing/mouse/clipboard/newline checks passed
odin run make.odin -file -- ime-test
    -> native X11 IME integration test passed
odin check src/core/editing -no-entry-point -vet -target:windows_amd64
odin check src/core/config -no-entry-point -vet -target:windows_amd64
    -> both Windows-target core checks passed
odin run make.odin -file -- windows
    -> blocked before source compilation: Unknown flag: 'ignore-vs-search'
```

The pinned compiler has no `odin fmt` command and no `odinfmt` executable is
installed. Formatting was reviewed manually.

## Limits and next task

- Windows product input, real desktop IM-server autopair behavior, and Wayland
  remain unvalidated.
- The policy is language-agnostic; it does not infer quote context, reindent
  bracketed lines, parse syntax, or reproduce the plugin's tree-sitter filtering.
- Next is M06.14: text zoom keybinds and Ctrl+mouse-wheel must reflow rendering,
  preserve caret/selection, and retain bounded atlas/cache ownership.
