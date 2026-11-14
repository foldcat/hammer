# 5. Repository structure

A suggested structure:

```text
/
├── AGENTS.md
├── README.md
├── ROADMAP.md
├── NEXT.md
├── CHANGELOG.md
├── docs/
│   ├── architecture.md
│   ├── acme-compatibility.md
│   ├── text-model.md
│   ├── transactions.md
│   ├── platform-matrix.md
│   ├── ipc-protocol.md
│   ├── filesystem-api.md
│   ├── persistence-formats.md
│   ├── performance-budget.md
│   ├── test-plan.md
│   └── adr/
├── src/
│   ├── app/
│   ├── core/
│   ├── text/
│   ├── actions/
│   ├── commands/
│   ├── layout/
│   ├── render/
│   ├── fonts/
│   ├── unicode/
│   ├── platform/
│   │   ├── windows/
│   │   ├── linux/
│   │   └── posix/
│   ├── clipboard/
│   ├── jobs/
│   ├── console/
│   ├── terminal/
│   ├── syntax/
│   ├── completion/
│   ├── editorconfig/
│   ├── history/
│   ├── recovery/
│   ├── projects/
│   ├── fuzzy/
│   ├── git/
│   ├── ipc/
│   └── fs_bridge/
├── config/
│   ├── schema.odin
│   ├── defaults.odin
│   └── user.example.odin
├── tools/
│   ├── build/
│   ├── acmectl/
│   ├── fs_adapter/
│   └── dependency_setup/
├── tests/
│   ├── unit/
│   ├── property/
│   ├── integration/
│   ├── compatibility/
│   ├── platform/
│   ├── crash/
│   ├── fixtures/
│   └── golden/
├── bench/
├── assets/
├── third_party/
└── build/
```

Avoid creating one enormous `editor.odin`.

However, also avoid premature abstraction: interfaces should exist because a real boundary needs them, not because every function needs an interface.
