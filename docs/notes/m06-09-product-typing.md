# M06.09 — Product typing and typed-text rendering

**Status:** done on Linux/X11. Real key events insert into a transactional product
buffer and render through the existing shaping/cache stack. The Windows product
cross-build has no text renderer because native fonts and shaping remain
Linux-only.

## Product editing

`src/editor.odin` owns one empty untitled `txn.Doc`, its view selection, typing
undo-group state, saved revision, and close guard. Normalized Sokol text and X11
IME commits now pass through `keybind.resolve_event` and `editing.perform`.
Movement, selection, deletion, indentation, undo, and redo use the existing core
actions. Consecutive text and IME commits share one undo group; movement,
deletion, indentation, undo, and redo break that run.

The saved revision starts at revision zero. Close, Escape, Ctrl+W, and Ctrl+Q all
inspect the same `lifecycle.Close_Guard`. Dirty text blocks closing rather than
being silently discarded. Save and explicit-discard UI remain later integration;
the existing log explains the blocked close.

## Text rendering

`src/text_render_linux.odin` shapes and draws the visible document lines with the
configured body face, pixel size, line height, ligature setting, and theme. It
uses the shaped clusters for selection spans, caret placement, and IME preedit
geometry. Preedit is displayed as a temporary insertion with an underline and
never mutates the document before commit.

Tabs remain single `\t` bytes in the document. `src/text/shaping/tabs.odin`
expands them for display to the next four-grapheme tab stop and maps source
offsets to expanded offsets for caret and selection geometry. Control-scalar IME
commits are ignored by key resolution so the X11 Tab commit cannot duplicate the
Tab key-down indentation action.

Glyph vertices are grouped by atlas page and uploaded once per frame. Quad
vertices likewise have one upload per frame; this respects Sokol's rule against
writing a transient buffer after binding it. `src/glyph_atlas.odin` now owns a
texture view beside every image and destroys both on replacement, DPI reset,
eviction, and shutdown.

Rendering does not flatten the document. It reads only visible lines, shapes at
most 64 KiB plus the existing 4 KiB grapheme lookahead per line, caps visible
lines at 4096, glyphs at 2048 per frame, and uses bounded quad buffers. A line
whose remaining text was not shaped gets a right-edge marker. Horizontal and
vertical scrolling are not part of this slice.

## Integration test

`make.odin -- typing-test` builds the product and runs
`tests/integration/typing/x11_harness.py` under an isolated Xvfb display. The
Python standard-library harness uses XTEST to send real key events and X11 pixel
reads to verify:

- `abc`, Enter, and `d` change the body text pixels;
- one Ctrl+Z undoes the complete typing run;
- Ctrl+Shift+Z redoes it and a second undo restores the initial pixels;
- `a`, Tab, `b` renders exactly like `a`, three spaces, `b`;
- Backspace deletes through the product dispatcher;
- Escape cannot close dirty text, and closing succeeds after returning to the
  saved revision.

The harness uses a unique temporary state directory, owns an external timeout,
and cleans up its child process and sandbox on success.

## Validation

```text
odin run make.odin -file -- typing-test
    -> Linux build and all real X11 typing/rendering checks passed
odin run make.odin -file -- test
    -> all 300 core unit tests passed, allocator tracking clean
odin run make.odin -file -- text-test
    -> all 28 native text tests passed; four visual golden hashes matched
odin run make.odin -file -- ime-test
    -> native X11 preedit/dead-key integration test passed
xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=12 \
    HAMMER_TEST_DPI_SCALES=1,1.25,1.5,2,1.5,1.25,1 \
    HAMMER_RENDER_PROBE=4 HAMMER_LOG= ./build/hammer
    -> DPI/cache transitions and exact render-color probe passed
odin run make.odin -file -- windows
xvfb-run -a env WINEDEBUG=-all HAMMER_AUTOQUIT_FRAMES=10 HAMMER_LOG= wine ./build/hammer.exe
    -> Windows cross-build and Wine lifecycle smoke passed
```

## Limits and next task

- No Windows text rendering, Wayland renderer, real IM server preedit, mouse hit
  testing, scrolling, product clipboard dispatch, or save/discard UI is claimed.
- M06.10 should make Enter inherit the current line's indentation in the same
  transaction, with core tests and product validation.
