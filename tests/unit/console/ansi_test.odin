// Tests for M10.02: the ANSI state machine and SGR style model. SGR
// interpretation is checked directly against the style model; the streaming
// parser is checked on byte sequences (decoded through the M10.01 decoder)
// and for chunk-boundary invariance.
package console_test

import "core:testing"

import console "hammer:core/console"

// --- Color/style helpers ------------------------------------------------

expect_default_color :: proc(t: ^testing.T, c: console.Color) {
	testing.expectf(t, c.kind == .Default, "expected default color, got %v", c)
}

expect_basic_color :: proc(t: ^testing.T, c: console.Color, index: u8) {
	testing.expectf(t, c.kind == .Basic, "expected basic color, got %v", c)
	if c.kind == .Basic {
		testing.expectf(t, c.index == index, "expected basic index %d, got %d", index, c.index)
	}
}

expect_palette_color :: proc(t: ^testing.T, c: console.Color, index: u8) {
	testing.expectf(t, c.kind == .Palette, "expected palette color, got %v", c)
	if c.kind == .Palette {
		testing.expectf(t, c.index == index, "expected palette index %d, got %d", index, c.index)
	}
}

expect_rgb_color :: proc(t: ^testing.T, c: console.Color, r, g, b: u8) {
	testing.expectf(t, c.kind == .RGB, "expected RGB color, got %v", c)
	if c.kind == .RGB {
		testing.expectf(t, c.rgb == [3]u8{r, g, b}, "expected RGB %d,%d,%d got %v", r, g, b, c.rgb)
	}
}

color_equal :: proc(a, b: console.Color) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .Default:
		return true
	case .Basic, .Palette:
		return a.index == b.index
	case .RGB:
		return a.rgb == b.rgb
	}
	return false
}

style_equal :: proc(a, b: console.Style) -> bool {
	return color_equal(a.fg, b.fg) &&
		color_equal(a.bg, b.bg) &&
		a.bold == b.bold &&
		a.dim == b.dim &&
		a.italic == b.italic &&
		a.underline == b.underline &&
		a.blink == b.blink &&
		a.reverse == b.reverse &&
		a.hidden == b.hidden &&
		a.strikethrough == b.strikethrough
}

runes_equal :: proc(a, b: []rune) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// runes_is compares a rune slice against the runes of an ASCII string without
// allocating.
runes_is :: proc(rs: []rune, want: string) -> bool {
	i := 0
	for r in want {
		if i >= len(rs) || rs[i] != r {
			return false
		}
		i += 1
	}
	return i == len(rs)
}

event_equal :: proc(a, b: console.Event) -> bool {
	switch x in a {
	case console.Text_Event:
		y, ok := b.(console.Text_Event)
		return ok && runes_equal(x.runes, y.runes)
	case console.Style_Event:
		y, ok := b.(console.Style_Event)
		return ok && style_equal(x.style, y.style)
	case console.Csi_Event:
		y, ok := b.(console.Csi_Event)
		if !ok || x.final != y.final || x.param_count != y.param_count {
			return false
		}
		for i in 0 ..< int(x.param_count) {
			if x.params[i] != y.params[i] {
				return false
			}
		}
		return true
	case console.Control_Event:
		y, ok := b.(console.Control_Event)
		return ok && x.rune == y.rune
	case console.Osc_Event:
		y, ok := b.(console.Osc_Event)
		return ok && runes_equal(x.payload, y.payload)
	}
	return false
}

events_equal :: proc(a, b: []console.Event) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if !event_equal(a[i], b[i]) {
			return false
		}
	}
	return true
}

// concat_text returns the concatenation of every Text event's runes, in order.
concat_text :: proc(events: []console.Event) -> [dynamic]rune {
	out := make([dynamic]rune, context.allocator)
	for e in events {
		if text, ok := e.(console.Text_Event); ok {
			append(&out, ..text.runes)
		}
	}
	return out
}

// without_text returns the non-Text events, in order.
without_text :: proc(events: []console.Event) -> [dynamic]console.Event {
	out := make([dynamic]console.Event, context.allocator)
	for e in events {
		if _, ok := e.(console.Text_Event); !ok {
			append(&out, e)
		}
	}
	return out
}

// events_equivalent compares two event streams ignoring how text runs were
// split at feed boundaries: the concatenated text must match exactly, and the
// sequence of non-text events must match exactly.
events_equivalent :: proc(a, b: []console.Event) -> bool {
	at := concat_text(a)
	defer delete(at)
	bt := concat_text(b)
	defer delete(bt)
	if !runes_equal(at[:], bt[:]) {
		return false
	}
	an := without_text(a)
	defer delete(an)
	bn := without_text(b)
	defer delete(bn)
	return events_equal(an[:], bn[:])
}

// --- Event assertion helpers --------------------------------------------

expect_text :: proc(t: ^testing.T, e: console.Event, want: string) {
	text, ok := e.(console.Text_Event)
	testing.expect(t, ok, "expected Text event")
	if ok {
		testing.expectf(t, runes_is(text.runes, want), "expected text %q, got %v", want, text.runes)
	}
}

expect_control :: proc(t: ^testing.T, e: console.Event, want: rune) {
	control, ok := e.(console.Control_Event)
	testing.expect(t, ok, "expected Control event")
	if ok {
		testing.expectf(t, control.rune == want, "expected control %d, got %d", want, control.rune)
	}
}

expect_csi :: proc(t: ^testing.T, e: console.Event, want_final: rune, want_params: ..u32) {
	csi, ok := e.(console.Csi_Event)
	testing.expect(t, ok, "expected Csi event")
	if ok {
		testing.expectf(t, csi.final == want_final, "expected final %c, got %c", want_final, csi.final)
		testing.expectf(t, int(csi.param_count) == len(want_params), "expected %d params, got %d", len(want_params), csi.param_count)
		for i in 0 ..< min(int(csi.param_count), len(want_params)) {
			testing.expectf(t, csi.params[i] == want_params[i], "param %d: expected %d, got %d", i, want_params[i], csi.params[i])
		}
	}
}

expect_osc :: proc(t: ^testing.T, e: console.Event, want: string) {
	osc, ok := e.(console.Osc_Event)
	testing.expect(t, ok, "expected Osc event")
	if ok {
		testing.expectf(t, runes_is(osc.payload, want), "expected OSC payload %q, got %v", want, osc.payload)
	}
}

style_of :: proc(e: console.Event) -> (console.Style, bool) {
	style, ok := e.(console.Style_Event)
	return style.style, ok
}

expect_style_fg_basic :: proc(t: ^testing.T, e: console.Event, index: u8) {
	style, ok := style_of(e)
	testing.expect(t, ok, "expected Style event")
	if ok {
		expect_basic_color(t, style.fg, index)
	}
}

expect_style_fg_palette :: proc(t: ^testing.T, e: console.Event, index: u8) {
	style, ok := style_of(e)
	testing.expect(t, ok, "expected Style event")
	if ok {
		expect_palette_color(t, style.fg, index)
	}
}

expect_style_fg_rgb :: proc(t: ^testing.T, e: console.Event, r, g, b: u8) {
	style, ok := style_of(e)
	testing.expect(t, ok, "expected Style event")
	if ok {
		expect_rgb_color(t, style.fg, r, g, b)
	}
}

expect_style_bg_rgb :: proc(t: ^testing.T, e: console.Event, r, g, b: u8) {
	style, ok := style_of(e)
	testing.expect(t, ok, "expected Style event")
	if ok {
		expect_rgb_color(t, style.bg, r, g, b)
	}
}

expect_style_default :: proc(t: ^testing.T, e: console.Event) {
	style, ok := style_of(e)
	testing.expect(t, ok, "expected Style event")
	if ok {
		expect_default_color(t, style.fg)
		expect_default_color(t, style.bg)
	}
}

// --- Parser feed helpers ------------------------------------------------

// clone_event deep-copies an event's borrowed rune slices so the result owns
// its data. Other event kinds are copied by value.
clone_event :: proc(e: console.Event) -> console.Event {
	#partial switch v in e {
	case console.Text_Event:
		rs := make([]rune, len(v.runes), context.allocator)
		copy(rs, v.runes)
		return console.Text_Event{runes = rs}
	case console.Osc_Event:
		rs := make([]rune, len(v.payload), context.allocator)
		copy(rs, v.payload)
		return console.Osc_Event{payload = rs}
	}
	return e
}

// delete_events frees an event list and any rune slices owned by cloned
// Text/Osc events.
delete_events :: proc(events: [dynamic]console.Event) {
	for e in events {
		#partial switch v in e {
		case console.Text_Event:
			delete(v.runes)
		case console.Osc_Event:
			delete(v.payload)
		}
	}
	delete(events)
}

// parse_chunked feeds a rune stream through a fresh parser in chunk-sized
// pieces, returning cloned (owned) events.
parse_chunked :: proc(runes: []rune, chunk: int) -> [dynamic]console.Event {
	events := make([dynamic]console.Event, context.allocator)
	p: console.Parser
	console.parser_init(&p, context.allocator)
	defer console.parser_destroy(&p)
	buf := make([]console.Event, max(chunk, 1), context.allocator)
	defer delete(buf)
	offset := 0
	for offset < len(runes) {
		end := min(offset + chunk, len(runes))
		for offset < end {
			written, consumed := console.feed(&p, runes[offset:end], buf)
			for e in buf[:written] {
				append(&events, clone_event(e))
			}
			offset += consumed
		}
	}
	return events
}

// feed_runes feeds a whole rune stream through a fresh parser.
feed_runes :: proc(runes: []rune) -> [dynamic]console.Event {
	return parse_chunked(runes, max(len(runes), 1))
}

// collect_events decodes a UTF-8 byte string and feeds the resulting runes
// through the parser.
collect_events :: proc(data: []byte) -> [dynamic]console.Event {
	runes := decode_with_chunk_size(data, max(len(data), 1))
	defer delete(runes)
	return feed_runes(runes[:])
}

// --- SGR interpretation -------------------------------------------------

@(test)
test_sgr_reset_and_default :: proc(t: ^testing.T) {
	s := console.Style{}
	console.style_reset(&s)
	expect_default_color(t, s.fg)
	expect_default_color(t, s.bg)
	testing.expect(t, !s.bold && !s.dim && !s.italic && !s.underline)
	testing.expect(t, !s.blink && !s.reverse && !s.hidden && !s.strikethrough)

	// SGR 0 resets a styled state back to default.
	console.apply_sgr(&s, []u32{1, 31, 0})
	expect_default_color(t, s.fg)
	expect_default_color(t, s.bg)
	testing.expect(t, !s.bold)
}

@(test)
test_sgr_basic_and_bright_colors :: proc(t: ^testing.T) {
	for code in 30 ..= 37 {
		s := console.Style{}
		console.apply_sgr(&s, []u32{u32(code)})
		expect_basic_color(t, s.fg, u8(code - 30))
		expect_default_color(t, s.bg)
	}
	for code in 40 ..= 47 {
		s := console.Style{}
		console.apply_sgr(&s, []u32{u32(code)})
		expect_basic_color(t, s.bg, u8(code - 40))
		expect_default_color(t, s.fg)
	}
	for code in 90 ..= 97 {
		s := console.Style{}
		console.apply_sgr(&s, []u32{u32(code)})
		expect_basic_color(t, s.fg, u8(code - 90 + 8))
	}
	for code in 100 ..= 107 {
		s := console.Style{}
		console.apply_sgr(&s, []u32{u32(code)})
		expect_basic_color(t, s.bg, u8(code - 100 + 8))
	}
}

@(test)
test_sgr_palette_and_true_color :: proc(t: ^testing.T) {
	s := console.Style{}
	console.apply_sgr(&s, []u32{38, 5, 196})
	expect_palette_color(t, s.fg, 196)
	expect_default_color(t, s.bg)

	s = console.Style{}
	console.apply_sgr(&s, []u32{48, 5, 21})
	expect_palette_color(t, s.bg, 21)
	expect_default_color(t, s.fg)

	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 2, 255, 128, 0})
	expect_rgb_color(t, s.fg, 255, 128, 0)

	s = console.Style{}
	console.apply_sgr(&s, []u32{48, 2, 1, 2, 3})
	expect_rgb_color(t, s.bg, 1, 2, 3)

	// Out-of-range palette/RGB channels clamp to 255.
	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 5, 999})
	expect_palette_color(t, s.fg, 255)
	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 2, 300, 256, 999})
	expect_rgb_color(t, s.fg, 255, 255, 255)

	// Malformed extended color leaves the color unchanged.
	s = console.Style{}
	console.apply_sgr(&s, []u32{38})
	expect_default_color(t, s.fg)
	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 7})
	expect_default_color(t, s.fg)
	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 5})
	expect_default_color(t, s.fg)
	s = console.Style{}
	console.apply_sgr(&s, []u32{38, 2, 1, 2})
	expect_default_color(t, s.fg)
}

@(test)
test_sgr_attributes_on_and_off :: proc(t: ^testing.T) {
	s := console.Style{}
	console.apply_sgr(&s, []u32{1, 2, 3, 4, 5, 7, 8, 9})
	testing.expect(t, s.bold && s.dim && s.italic && s.underline)
	testing.expect(t, s.blink && s.reverse && s.hidden && s.strikethrough)

	console.apply_sgr(&s, []u32{22})
	testing.expect(t, !s.bold && !s.dim)
	console.apply_sgr(&s, []u32{23, 24, 25, 27, 28, 29})
	testing.expect(t, !s.italic && !s.underline && !s.blink && !s.reverse && !s.hidden && !s.strikethrough)

	// 21 turns off bold alone.
	s = console.Style{}
	console.apply_sgr(&s, []u32{1})
	testing.expect(t, s.bold)
	console.apply_sgr(&s, []u32{21})
	testing.expect(t, !s.bold)
}

@(test)
test_sgr_combined_and_unknown :: proc(t: ^testing.T) {
	s := console.Style{}
	console.apply_sgr(&s, []u32{1, 31, 44, 99, 12345})
	testing.expect(t, s.bold)
	expect_basic_color(t, s.fg, 1)
	expect_basic_color(t, s.bg, 4)

	// An empty parameter list is SGR 0 (reset).
	s = console.Style{}
	console.apply_sgr(&s, []u32{1, 31})
	console.apply_sgr(&s, []u32{})
	expect_default_color(t, s.fg)
	expect_default_color(t, s.bg)
	testing.expect(t, !s.bold)
}

// --- Parser -------------------------------------------------------------

@(test)
test_parser_plain_text :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("hello"))
	defer delete_events(events)
	testing.expect(t, len(events) == 1)
	if len(events) == 1 {
		expect_text(t, events[0], "hello")
	}
}

@(test)
test_parser_sgr_style_and_reset :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("\x1b[31mred\x1b[0mplain"))
	defer delete_events(events)
	testing.expectf(t, len(events) == 4, "expected 4 events, got %d", len(events))
	if len(events) == 4 {
		expect_style_fg_basic(t, events[0], 1)
		expect_text(t, events[1], "red")
		expect_style_default(t, events[2])
		expect_text(t, events[3], "plain")
	}
}

@(test)
test_parser_bright_true_color_sequences :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("\x1b[95mhi"))
	defer delete_events(events)
	testing.expect(t, len(events) == 2)
	if len(events) == 2 {
		expect_style_fg_basic(t, events[0], 13)
		expect_text(t, events[1], "hi")
	}

	events2 := collect_events(transmute([]byte)string("\x1b[38;5;208mx\x1b[48;2;10;20;30m"))
	defer delete_events(events2)
	testing.expect(t, len(events2) == 3)
	if len(events2) == 3 {
		expect_style_fg_palette(t, events2[0], 208)
		expect_text(t, events2[1], "x")
		expect_style_bg_rgb(t, events2[2], 10, 20, 30)
	}
}

@(test)
test_parser_control_characters :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("a\rb\nc\td\x07"))
	defer delete_events(events)
	// a, CR, b, LF, c, TAB, d, BEL -> text runs and control events interleaved.
	testing.expect(t, len(events) == 8)
	if len(events) == 8 {
		expect_text(t, events[0], "a")
		expect_control(t, events[1], '\r')
		expect_text(t, events[2], "b")
		expect_control(t, events[3], '\n')
		expect_text(t, events[4], "c")
		expect_control(t, events[5], '\t')
		expect_text(t, events[6], "d")
		expect_control(t, events[7], '\x07')
	}
}

@(test)
test_parser_escape_and_csi_sequences :: proc(t: ^testing.T) {
	// A single-character escape is ignored; an unknown CSI sequence becomes a
	// Csi event with its parameters.
	events := collect_events(transmute([]byte)string("\x1b7\x1b[2J\x1b[?25l"))
	defer delete_events(events)
	testing.expect(t, len(events) == 2)
	if len(events) == 2 {
		expect_csi(t, events[0], 'J', 2)
		expect_csi(t, events[1], 'l', 25)
	}
}

@(test)
test_parser_osc_payload :: proc(t: ^testing.T) {
	events := collect_events(transmute([]byte)string("\x1b]0;title\x07x"))
	defer delete_events(events)
	testing.expect(t, len(events) == 2)
	if len(events) == 2 {
		expect_osc(t, events[0], "0;title")
		expect_text(t, events[1], "x")
	}

	// ST (ESC \) terminates too.
	events2 := collect_events(transmute([]byte)string("\x1b]8;;url\x1b\\"))
	defer delete_events(events2)
	testing.expect(t, len(events2) == 1)
	if len(events2) == 1 {
		expect_osc(t, events2[0], "8;;url")
	}
}

@(test)
test_parser_chunk_split_sequences :: proc(t: ^testing.T) {
	data := transmute([]byte)string("\x1b[38;2;1;2;3mhello\x1b[0m")
	runes := decode_with_chunk_size(data, max(len(data), 1))
	defer delete(runes)

	whole := feed_runes(runes[:])
	defer delete_events(whole)
	testing.expect(t, len(whole) == 3)
	if len(whole) == 3 {
		expect_style_fg_rgb(t, whole[0], 1, 2, 3)
		expect_text(t, whole[1], "hello")
		expect_style_default(t, whole[2])
	}

	for chunk := 1; chunk <= len(runes); chunk += 1 {
		events := parse_chunked(runes[:], chunk)
		testing.expectf(t, events_equivalent(events[:], whole[:]), "chunk %d differs", chunk)
		delete_events(events)
	}
}

@(test)
test_parser_cancel_on_control_inside_csi :: proc(t: ^testing.T) {
	// A control character (LF) inside a CSI sequence cancels it; the LF is
	// then emitted as a control event and parsing continues.
	events := collect_events(transmute([]byte)string("\x1b[31\nx"))
	defer delete_events(events)
	testing.expect(t, len(events) == 2)
	if len(events) == 2 {
		expect_control(t, events[0], '\n')
		expect_text(t, events[1], "x")
	}
}

@(test)
test_parser_partial_consumption :: proc(t: ^testing.T) {
	data := transmute([]byte)string("alpha\x1b[31mbeta\x1b[0mgamma")
	whole := collect_events(data)
	defer delete_events(whole)

	runes := decode_with_chunk_size(data, len(data))
	defer delete(runes)

	events := make([dynamic]console.Event, context.allocator)
	defer delete_events(events)
	p: console.Parser
	console.parser_init(&p, context.allocator)
	defer console.parser_destroy(&p)
	buf := make([]console.Event, 2, context.allocator)
	defer delete(buf)
	offset := 0
	guard := 0
	for offset < len(runes) && guard < 100000 {
		written, consumed := console.feed(&p, runes[offset:], buf)
		testing.expect(t, written > 0 || consumed > 0)
		for e in buf[:written] {
			append(&events, clone_event(e))
		}
		offset += consumed
		guard += 1
	}
	testing.expect(t, offset == len(runes))
	testing.expect(t, events_equivalent(events[:], whole[:]))
}

@(test)
test_parser_chunk_invariance :: proc(t: ^testing.T) {
	state := u64(0x9e3779b97f4a7c15)
	for _ in 0 ..< 1000 {
		state = xorshift64(state)
		n := int(state % 80)
		data := make([]byte, n, context.allocator)
		for i in 0 ..< n {
			state = xorshift64(state)
			data[i] = u8(state >> 32)
		}
		runes := decode_with_chunk_size(data, max(n, 1))
		whole := feed_runes(runes[:])

		state = xorshift64(state)
		chunk := 1 + int(state % 16)
		events := parse_chunked(runes[:], chunk)

		testing.expect(t, events_equivalent(events[:], whole[:]))

		delete_events(events)
		delete_events(whole)
		delete(runes)
		delete(data)
	}
}

@(test)
test_parser_trailing_incomplete_escape :: proc(t: ^testing.T) {
	// A trailing ESC or truncated CSI sequence produces no events.
	events := feed_runes([]rune{'\x1b'})
	testing.expect(t, len(events) == 0)
	delete_events(events)

	events = feed_runes([]rune{'\x1b', '[', '3', '1'})
	testing.expect(t, len(events) == 0)
	delete_events(events)

	// A fresh stream still parses cleanly.
	events = feed_runes([]rune{'o', 'k'})
	defer delete_events(events)
	testing.expect(t, len(events) == 1)
	if len(events) == 1 {
		expect_text(t, events[0], "ok")
	}
}
