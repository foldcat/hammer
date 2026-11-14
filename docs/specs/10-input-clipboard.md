# 10. Input and clipboard

## 10.1 Unified action dispatch

All input maps to semantic actions:

```text
Select
ExtendSelection
ExecuteText
LookText
Copy
Cut
Paste
Undo
Redo
Indent
Outdent
MoveCursor
OpenFinder
CloseWindow
RequestQuit
```

Mouse, keyboard, touchpad modifiers, IPC, and textual commands should share the same action layer where semantics match.

## 10.2 Mouse state machine

Track:

- Pressed buttons.
- Initial target.
- Drag threshold.
- Selection origin.
- Chord state.
- Modifier state at gesture start.
- Gesture cancellation.
- Lost focus/capture.

Test original Acme chords against the reference behavior.

Do not automatically enable X11 middle-click paste over Acme’s middle-button execution behavior.

## 10.3 Touchpad defaults

Suggested configurable defaults:

| Gesture                   | Action           |
| ------------------------- | ---------------- |
| Plain primary click/drag  | Select           |
| Ctrl + primary click/drag | Execute          |
| Alt + primary click/drag  | Look             |
| Shift + primary click     | Extend selection |

Potential conflicts:

- Alt-drag may be intercepted by a Linux window manager.
- Platform-specific shortcuts can interfere.
- Modifier-assisted clicks must not accidentally begin a text drag.

Therefore provide alternate bindings, such as:

```text
Ctrl+Enter  Execute selection/token
Alt+Enter   Look selection/token
```

Use keydown actions for shortcuts and text-input events for inserted text.

## 10.4 Modern keyboard defaults

| Binding            | Action                      |
| ------------------ | --------------------------- |
| Ctrl+C             | Copy                        |
| Ctrl+X             | Cut                         |
| Ctrl+V             | Paste                       |
| Ctrl+Z             | Undo                        |
| Ctrl+Shift+Z       | Redo                        |
| Ctrl+Y             | Optional redo alias         |
| Ctrl+A             | Select all                  |
| Ctrl+S             | Put/save                    |
| Ctrl+Shift+S       | Save as                     |
| Ctrl+F             | Find                        |
| Ctrl+P             | Fuzzy file finder           |
| Ctrl+W             | Close current window safely |
| Ctrl+Q             | Request quit safely         |
| Shift+arrows       | Extend selection            |
| Ctrl+arrows        | Word movement               |
| Ctrl+Shift+arrows  | Word selection              |
| Home/End           | Line movement               |
| Shift+Home/End     | Extend to line boundary     |
| Tab with selection | Indent selected lines       |
| Shift+Tab          | Outdent                     |

Handle AltGr correctly. A Ctrl+Alt key combination used to produce text must not trigger an unrelated command.

## 10.5 Indentation behavior

When a multiline selection is active:

- `Tab` indents every covered line.
- `Shift+Tab` removes one indentation unit.
- The operation is one undo transaction.
- Preserve selection direction.
- Adjust selection anchors.
- Respect EditorConfig indentation settings.

Define the boundary rule:

> If a selection ends exactly at the start of a line, that final line is not included unless the selection actually covers its content.

When no selection exists:

- Insert a tab or indentation spaces according to effective settings.

## 10.6 Clipboard service

Use a platform service:

```text
ClipboardRequest
ClipboardResult
ClipboardOwnership
ClipboardError
```

Clipboard operations may be asynchronous even if a particular OS API is synchronous.

### Windows

Use native Unicode clipboard handling.

Requirements:

- UTF-16 conversion.
- Correct ownership/lifetime rules.
- Bounded retry if another application temporarily holds the clipboard.
- Correct empty clipboard behavior.
- No fixed small buffer limit.

### X11

Handle:

- `CLIPBOARD`.
- Optional `PRIMARY`, separately configurable.
- Ownership.
- UTF-8 targets.
- Large transfers, including incremental transfer behavior.
- Clipboard-manager persistence where available.

### Wayland

Use the supported native clipboard mechanism.

Requirements:

- Correct seat/focus/serial integration where required.
- Asynchronous transfer.
- Tested behavior on supported compositors.
- No shelling out to `wl-copy` as the primary implementation.

### Contract

Copy should publish the current selection to the real system clipboard.

Paste should retrieve the current system clipboard, not an old internal copy.

Keep a private fallback only if:

- It is explicitly identified as a fallback.
- A visible error explains the native failure.
- The application does not pretend the fallback is the system clipboard.

### Delayed paste safety

A paste request captures:

- Target buffer.
- Target selection anchors.
- Target generation.
- Request ID.

If focus changes or the target disappears, do not paste into whichever window is currently active.

### “Works all the time” realism

The editor can eliminate its own clipboard bugs, but it cannot guarantee success if the OS denies access, the compositor disconnects, or the clipboard is temporarily locked.

The practical requirement is:

- Reliable operation throughout the supported session.
- Bounded retries.
- Correct ownership.
- Explicit errors.
- No silent stale paste.
- Persistence after exit where the platform/session supports it.

On X11/Wayland, persistence after application exit is a separate ownership problem. Clipboard-manager handoff or a supported long-lived owner may be needed. This must be tested rather than assumed. [4]
