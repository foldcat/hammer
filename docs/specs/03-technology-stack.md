# 3. Recommended technology stack

## 3.1 Core

**Odin**

Use Odin for:

- Editor state.
- Text engine.
- Transactions.
- Layout.
- Input routing.
- Job orchestration.
- Project services.
- IPC dispatch.
- Persistence.
- Tests and benchmarks.

## 3.2 Application and rendering

**Sokol**

Use:

- `sokol_app` for the application shell where supported.
- `sokol_gfx` for GPU rendering.
- `sokol_glue` for backend integration where appropriate.
- Sokol shader tooling for portable shader generation.

Pin exact versions of:

- Odin.
- Sokol C headers.
- Odin Sokol bindings.
- Shader compiler tooling.

Do not assume every platform feature is available in the selected Sokol revision. Clipboard, IME, native Wayland support, per-monitor DPI, and idle-loop behavior require an early platform spike.

### Important boundary

Sokol is not the editor’s:

- Text engine.
- Shaping engine.
- Terminal emulator.
- Filesystem service.
- Command executor.

It is the application/rendering foundation.

## 3.3 Text rendering

Recommended:

- **FreeType** for font loading and glyph rasterization.
- **HarfBuzz** for shaping.
- A pinned Unicode implementation for:
  - Grapheme boundaries.
  - Word boundaries.
  - Bidirectional layout.
  - Character properties.

Choose one complete Unicode strategy early:

- ICU, or
- Smaller Unicode components plus a dedicated bidi implementation.

Do not assume HarfBuzz alone implements cursor movement, Unicode segmentation, or full paragraph bidi handling.

Existing Odin bindings for FreeType and HarfBuzz are available, but they should be audited and pinned rather than copied blindly. [2]

## 3.4 Syntax highlighting

**Tree-sitter**

Use:

- Incremental parsing.
- Highlight queries.
- Optional injections after basic highlighting works.

There are existing Odin Tree-sitter bindings that can reduce initial integration work. Pin the runtime, binding, grammar, scanner, and query versions together. [3]

## 3.5 Other dependencies

Recommended initial choices:

| Capability                       | Approach                                                          |
| -------------------------------- | ----------------------------------------------------------------- |
| Font discovery on Windows        | DirectWrite/system font APIs                                      |
| Font discovery on Linux          | Fontconfig                                                        |
| Git status/diff                  | `git` subprocesses first                                          |
| EditorConfig                     | Official library or a thoroughly tested compatible implementation |
| Local IPC on Unix                | Unix-domain sockets                                               |
| Local IPC on Windows             | Named pipes                                                       |
| Filesystem mount on Unix         | FUSE adapter                                                      |
| Filesystem mount on Windows      | WinFsp adapter                                                    |
| Interactive processes on Unix    | PTY                                                               |
| Interactive processes on Windows | ConPTY where supported                                            |

Keep dependencies behind narrow interfaces.

Do not write a font shaper, terminal emulator, Unicode implementation, and Git implementation just to keep the dependency list short.
