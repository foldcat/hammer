# 1. Product definition

~~Use a temporary project name such as **Acme Next** until naming and trademark questions are settled.~~ Let's call it hammer (`hm`), because when all you have is a hammer, everything can become nails...

## 1.1 Required experience

The editor should support:

| Area          | Required behavior                                                                 |
| ------------- | --------------------------------------------------------------------------------- |
| Interaction   | Acme selection, execution, lookup, mouse chording, editable tags                  |
| Touchpads     | Modifier-assisted equivalents for middle/right mouse actions                      |
| Keyboard      | Copy, paste, cut, undo, redo, selection movement, indentation                     |
| Text engine   | Rope-backed editing, efficient large-file access, multiple views                  |
| Rendering     | Unicode shaping, font fallback, configurable fonts and colors                     |
| Platforms     | Windows and Linux/Unix, with explicit backend support                             |
| Clipboard     | Real native system clipboard, not a private editor clipboard pretending to be one |
| Commands      | Asynchronous execution, cancellation, output windows, selection pipes             |
| Console       | Unicode output, ANSI styles, progress-line handling, optional PTY terminals       |
| Parsing       | Incremental Tree-sitter highlighting                                              |
| Completion    | Lightweight buffer-word completion                                                |
| Safety        | Safe save, shutdown protection, swap/recovery files                               |
| History       | Persistent branching undo history with an interactive tree                        |
| Projects      | Persistent layout, fuzzy finder, lightweight Git indicators                       |
| Configuration | Trusted Odin configuration compiled into the application                          |
| Automation    | Modern local IPC plus filesystem-visible state and control                        |
| Compatibility | A documented Acme behavior matrix and executable compatibility tests              |

## 1.2 Platform promise

Avoid saying “supports Unix” without specifying what that means.

Recommended release tiers:

### Tier 1

- Linux on X11. Prioritize X11 over Wayland. Prioritize Linux over Windows.
- Windows 10/11, subject to the minimum supported versions of dependencies.
- Linux on Wayland, with the chosen Sokol/native integration actually tested.

### Tier 2

- Other POSIX systems, such as FreeBSD.
- macOS if desired.

The core should be portable, but a POSIX abstraction does not automatically provide working fonts, clipboard, DPI, IME, or filesystem mounting on every Unix-like system.

## 1.3 Explicit non-goals for version 1

These keep the project manageable:

- No built-in LSP requirement.
- No extension marketplace.
- No embedded browser.
- No collaborative editing.
- No remote network server enabled by default.
- No full Git client.
- No mandatory terminal emulator in every command window.
- No runtime compilation of untrusted project configuration.
- No promise that existing 9P clients work unchanged.
- No AI integration.

A later compatibility adapter can support old clients, but the main architecture should not depend on 9P.
