# Roadmap — Hammer (`hm`)

A modern Acme reimagining in Odin + Sokol.

This directory tracks milestone and task status, split into one file
per milestone (`m00.md` … `m20.md`). The plan itself lives in
`SPECS.md` §18 ("Implementation roadmap"); deliverables, dependencies,
and acceptance criteria are defined there and are **not** duplicated
here except as short reminders. When SPECS.md and these files disagree
about _what_ a task is, SPECS.md wins; these files only record
_status_.

Per SPECS.md §19.1, exactly one milestone is active at a time. The
active task, allowed scope, and acceptance criteria for the current
session live in `NEXT.md`.

## Status legend

| Mark  | Meaning                                                |
| ----- | ------------------------------------------------------ |
| `[x]` | Done: implemented, tested where applicable, documented |
| `[~]` | In progress                                            |
| `[ ]` | Not started                                            |
| `[!]` | Blocked (see notes)                                    |

"Done" follows SPECS.md §19.4 and AGENTS.md §24: no acceptance-path
stubs, validation actually run, platform claims recorded honestly.

## Milestone overview

| ID      | Title                                              | Depends on     | Release cut | Status      |
| ------- | -------------------------------------------------- | -------------- | ----------- | ----------- |
| [M00](m00.md) | Specification, feasibility spikes, build baseline  | —              | —           | Done        |
| [M01](m01.md) | Application shell, platform layer, compiled config | M00            | Alpha A     | **Done**    |
| [M02](m02.md) | Rope, transactions, anchors, headless core         | M01            | Alpha A     | **Done**    |
| [M03](m03.md) | File loading, codecs, safe save, external changes  | M02            | Alpha A     | **Done**    |
| [M04](m04.md) | Recovery journals, persistent history, shutdown    | M03            | Alpha A     | **Done**    |
| [M05](m05.md) | Unicode text renderer, fonts, DPI                  | M02 (+M03/M04) | Alpha A     | In progress |
| [M06](m06.md) | Editing input, shortcuts, clipboard, indentation   | M04, M05       | Alpha A     | Not started |
| [M07](m07.md) | Acme columns, windows, tags, mouse, lookup         | M06            | Alpha B     | Not started |
| [M08](m08.md) | Address language, internal commands, Acme Edit     | M07            | Alpha B     | Not started |
| [M09](m09.md) | Asynchronous external commands, selection pipes    | M08            | Alpha B     | Not started |
| [M10](m10.md) | Unicode ANSI console, PTY/ConPTY terminal mode     | M09            | Beta        | Not started |
| [M11](m11.md) | EditorConfig and compiled-config workflow          | M06, M09       | Beta        | Not started |
| [M12](m12.md) | Incremental Tree-sitter highlighting               | M02, M05, M11  | Beta        | Not started |
| [M13](m13.md) | Lightweight buffer completion                      | M06, M12       | Beta        | Not started |
| [M14](m14.md) | Interactive persistent undo tree                   | M04, M07       | Beta        | Not started |
| [M15](m15.md) | Fuzzy finder and project indexing                  | M07, M09       | Beta        | Not started |
| [M16](m16.md) | Persistent per-project layout and restoration      | M04, M07, M15  | Beta        | Not started |
| [M17](m17.md) | Lightweight Git state and change navigation        | M09, M15, M16  | Beta        | Not started |
| [M18](m18.md) | Modern local IPC and command-line client           | M08, M09, M16  | RC          | Not started |
| [M19](m19.md) | Filesystem projection and live FS adapters         | M18            | RC          | Not started |
| [M20](m20.md) | Compatibility completion, hardening, release       | all required   | RC          | Not started |

## Release cuts (SPECS.md §24)

| Cut               | Through | Content                                                                                          |
| ----------------- | ------- | ------------------------------------------------------------------------------------------------ |
| Internal Alpha A  | M06     | Rope, safe save, recovery, undo, fonts, clipboard, modern keyboard input                         |
| Internal Alpha B  | M09     | Columns, tags, mouse/touchpad workflow, Look, Address/Edit, async commands                       |
| Beta              | M17     | ANSI console, EditorConfig, Tree-sitter, completion, history UI, finder, layout, Git indicators  |
| Release candidate | M20     | IPC, filesystem projection/mounts, compatibility hardening, packaging, cross-platform validation |
