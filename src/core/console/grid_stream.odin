// Grid stream — M10.07.
//
// Grid_Stream composes the chunk-safe UTF-8 decoder (decode.odin) and the ANSI
// state machine (ansi.odin) with a Grid (grid.odin): raw process bytes become
// grid updates. It is the model-B counterpart of Stream (stream.odin), which
// feeds a Line_Buffer instead. Decoding and parsing are shared; only the
// terminal consumer differs.
package console

import "base:runtime"

import errs "../errs"

// GRID_RUNE_BUF / GRID_EVENT_BUF size the scratch buffers, mirroring the
// Stream constants (event buffer >= rune buffer so feed consumes a full rune
// batch per call).
GRID_RUNE_BUF :: 512
GRID_EVENT_BUF :: 512

// Grid_Stream owns a Grid plus the decoder/parser scratch state that turns
// bytes into events. It is a fixed-location value; do not copy it.
Grid_Stream :: struct {
	allocator: runtime.Allocator,
	decoder:   Decoder,
	parser:    Parser,
	grid:      Grid,
	runes:     [dynamic]rune,
	events:    [dynamic]Event,
}

// grid_stream_init prepares s with a grid of rows×cols and max_scrollback.
grid_stream_init :: proc(
	s: ^Grid_Stream,
	rows, cols, max_scrollback: int,
	allocator := context.allocator,
) -> errs.Error {
	if s == nil {
		return errs.new(.Invalid_Input, "console: grid stream is nil", allocator = allocator)
	}
	s^ = {allocator = allocator}
	if err := parser_init(&s.parser, allocator); !errs.ok(err) {
		s^ = {}
		return err
	}
	if err := grid_init(&s.grid, rows, cols, max_scrollback, allocator); !errs.ok(err) {
		parser_destroy(&s.parser)
		s^ = {}
		return err
	}
	s.runes = make([dynamic]rune, allocator)
	resize(&s.runes, GRID_RUNE_BUF)
	s.events = make([dynamic]Event, allocator)
	resize(&s.events, GRID_EVENT_BUF)
	return {}
}

// grid_stream_destroy releases the stream's storage (the grid, parser, and
// scratch buffers).
grid_stream_destroy :: proc(s: ^Grid_Stream) {
	if s == nil {
		return
	}
	grid_destroy(&s.grid)
	delete(s.runes)
	delete(s.events)
	parser_destroy(&s.parser)
	s^ = {}
}

// grid_stream_feed consumes raw output bytes, updating the grid. It consumes
// all of input; the grid's dirty flag reports whether anything changed.
grid_stream_feed :: proc(s: ^Grid_Stream, input: []byte) -> errs.Error {
	if s == nil || s.allocator.procedure == nil {
		return errs.new(.Invalid_Input, "console: grid stream is not initialized")
	}
	remaining := input
	for len(remaining) > 0 {
		written, consumed := decode(&s.decoder, remaining, s.runes[:])
		if consumed == 0 && written == 0 {
			return errs.new(.Internal, "console: decoder made no progress")
		}
		grid_stream_feed_runes(s, s.runes[:written])
		remaining = remaining[consumed:]
	}
	return {}
}

grid_stream_feed_runes :: proc(s: ^Grid_Stream, runes: []rune) {
	remaining := runes
	for len(remaining) > 0 {
		written, consumed := feed(&s.parser, remaining, s.events[:])
		grid_feed(&s.grid, s.events[:written])
		remaining = remaining[consumed:]
	}
}
