# Project blueprint: a modern Acme in Odin + Sokol

The central idea should be:

> **Keep Acme’s interaction model, programmable text interface, columns, tags, and mouse workflow—but rebuild the implementation around a modern text engine, native platform integration, asynchronous jobs, and a versioned local API with filesystem access.**

Do **not** build a conventional IDE and apply Acme colors to it. The editor should still feel like Acme:

- Text is both content and interface.
- Commands are editable text.
- Selecting, executing, and looking up text are fundamental actions.
- Multiple windows can show the same buffer.
- External programs can create and manipulate editor windows.
- The filesystem interface is a first-class capability, not an afterthought.

At the same time, “original behavior” should not mean preserving clipboard bugs, poor font support, synchronous command execution, or unsafe data-loss behavior.

This plan is designed to become a repository’s architecture document, roadmap, and coding-agent operating procedure.

---

The blueprint has been split into one file per section under [`docs/specs/`](docs/specs/). Each file keeps its original section number and heading. References elsewhere in the repo of the form `SPECS.md §N` (e.g. `SPECS.md §14`, `SPECS.md §18`) resolve through the table below.

## Sections

| §   | Title                                                              | File                                                                 |
| --- | ------------------------------------------------------------------ | -------------------------------------------------------------------- |
| 1   | Product definition                                                 | [`docs/specs/01-product-definition.md`](docs/specs/01-product-definition.md) |
| 2   | Preserve Acme’s contract before modernizing it                     | [`docs/specs/02-acme-contract.md`](docs/specs/02-acme-contract.md)   |
| 3   | Recommended technology stack                                       | [`docs/specs/03-technology-stack.md`](docs/specs/03-technology-stack.md) |
| 4   | High-level architecture                                            | [`docs/specs/04-architecture.md`](docs/specs/04-architecture.md)     |
| 5   | Repository structure                                               | [`docs/specs/05-repository-structure.md`](docs/specs/05-repository-structure.md) |
| 6   | Core data model                                                    | [`docs/specs/06-data-model.md`](docs/specs/06-data-model.md)         |
| 7   | Text engine: a persistent piece-rope                               | [`docs/specs/07-text-engine.md`](docs/specs/07-text-engine.md)       |
| 8   | Transactions, selections, and undo                                 | [`docs/specs/08-transactions.md`](docs/specs/08-transactions.md)     |
| 9   | Rendering, Unicode, fonts, and DPI                                 | [`docs/specs/09-rendering.md`](docs/specs/09-rendering.md)           |
| 10  | Input and clipboard                                                | [`docs/specs/10-input-clipboard.md`](docs/specs/10-input-clipboard.md) |
| 11  | File safety, recovery, and shutdown                                | [`docs/specs/11-file-safety.md`](docs/specs/11-file-safety.md)       |
| 12  | Asynchronous commands and modern console support                   | [`docs/specs/12-commands-console.md`](docs/specs/12-commands-console.md) |
| 13  | Tree-sitter and lightweight completion                             | [`docs/specs/13-syntax-completion.md`](docs/specs/13-syntax-completion.md) |
| 14  | Configuration and EditorConfig                                     | [`docs/specs/14-configuration.md`](docs/specs/14-configuration.md)   |
| 15  | Interactive undo tree, finder, layout, and Git                     | [`docs/specs/15-history-finder-git.md`](docs/specs/15-history-finder-git.md) |
| 16  | Replace 9P with modern IPC while keeping filesystem access         | [`docs/specs/16-ipc-filesystem.md`](docs/specs/16-ipc-filesystem.md) |
| 17  | Performance and efficiency requirements                            | [`docs/specs/17-performance.md`](docs/specs/17-performance.md)       |
| 18  | Implementation roadmap                                             | [`docs/specs/18-roadmap.md`](docs/specs/18-roadmap.md)               |
| 19  | What the agent should implement every time                         | [`docs/specs/19-agent-procedure.md`](docs/specs/19-agent-procedure.md) |
| 20  | Suggested `AGENTS.md`                                              | [`docs/specs/20-agents-suggested.md`](docs/specs/20-agents-suggested.md) |
| 21  | Suggested `NEXT.md` format                                         | [`docs/specs/21-next-format.md`](docs/specs/21-next-format.md)       |
| 22  | Testing strategy                                                   | [`docs/specs/22-testing.md`](docs/specs/22-testing.md)               |
| 23  | Highest-risk parts                                                 | [`docs/specs/23-risks.md`](docs/specs/23-risks.md)                   |
| 24  | Recommended first usable release cuts                              | [`docs/specs/24-release-cuts.md`](docs/specs/24-release-cuts.md)     |
| —   | Final recommendation                                               | [`docs/specs/25-final-recommendation.md`](docs/specs/25-final-recommendation.md) |
