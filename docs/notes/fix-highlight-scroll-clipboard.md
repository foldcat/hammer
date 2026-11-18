# Bugfix — selection rendering, scroll-selection, and clipboard no-owner

**Status:** done on Linux/X11. Windows source type-checks; native Windows/Wine
runtime was not exercised.

Three small user-visible bugs, fixed together:

## 1. Descender/tall glyphs overflowed the selection highlight

Body text laid its baseline out with a fixed `TEXT_PADDING` top gap instead of
centring the glyph box within the line height. Glyphs whose ink reaches the
font descender (`p`, `q`, `g`, `j`, `y`) or the full ascent-to-descent range
(`{`, `}`) therefore rendered below the selection highlight rectangle, making
the "tail" of `p` (and the curls of `{}`) stick out past the highlight.

`src/text_render_native.odin` now computes the glyph box height from the
FreeType ascender/descender and vertically centres it within `line_height` for
body text, matching the tag-renderer path that already did this. The selection
and caret rectangles are unchanged; only the baseline moved so glyphs stay
inside the line box.

## 2. Wheel scrolling cancelled an active selection drag

`editor_scroll` called `editor_cancel_pointer_gesture()` unconditionally, so
scrolling while holding the primary button dropped the drag and froze the
selection.

`src/mouse_ui.odin` now keeps a primary-button Select gesture alive when the
scrolled window is the gesture's own body. After the viewport moves, it re-hits
the gesture at the pointer position and extends the active edge to whatever text
now sits under the pointer. Any other gesture is still cancelled by scrolling.

## 3. "selection has no owner" clipboard read was reported as an error

A paste against an empty CLIPBOARD/PRIMARY selection produced a `.NotFound`
error that `editor_poll_clipboard` forwarded to the generic reporter, opening an
error window and logging a warning. An empty selection is a normal paste no-op,
not an error.

`src/editor.odin` now treats a `.NotFound` clipboard result as a silent no-op:
it destroys the error and logs one info line, without a warning or error window.
All other clipboard error kinds keep their existing reporting.

## Validation

Using pinned Odin `dev-2026-11` and Sokol bindings `ae94aa5`:

```text
odin check src -vet -collection:sokol=third_party/sokol/sokol
    -> passed
odin check src -target:windows_amd64 -vet -collection:sokol=third_party/sokol/sokol -define:SOKOL_USE_GL=true
    -> passed
odin run make.odin -file -- text-test
    -> 40/40 native tests passed; four visual goldens matched
odin run make.odin -file -- typing-test --no-config
    -> all typing/mouse/clipboard/zoom/save checks passed
odin run make.odin -file -- mouse-test
    -> all mouse/chord checks passed, including the new silent-empty-paste check
odin run make.odin -file -- scroll-test
    -> soft and truncate viewport/scrollbar checks passed, including the new
       wheel-scroll-while-selecting check
odin run make.odin -file -- tag-test
    -> tag editing/clipping checks passed
odin run make.odin -file -- wrap-test
    -> soft/truncate wrap checks passed
odin run make.odin -file -- clipboard-test
    -> 4/4 native tests and all interop checks passed
odin run make.odin -file -- test
    -> all core unit tests passed
```

The descender-overflow fix was additionally confirmed visually under Xvfb by
selecting `p{}` and reading back the selection highlight: the glyph ink is now
fully contained within the highlight rectangle (previously the `p` and `}`
descenders rendered below it).

## Not validated

- No native Windows/Wine run of the text renderer (source type-check only).
- No Wayland or real-desktop visual review.
- No real X11 clipboard manager; only the no-owner and separate-process interop
  paths were exercised.

## Risks/blockers

None. The three changes are localized to the product layer (`package main`) and
two X11 test harnesses; no core or platform contract changed.

## Next task

M08.01 (command dispatch and context), as recorded in NEXT.md.
