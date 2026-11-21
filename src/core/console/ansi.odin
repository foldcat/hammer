// ANSI state machine and SGR styles (M10.02).
//
// This file consumes the rune stream produced by the chunk-safe UTF-8 decoder
// (`decode.odin`) and recognizes ANSI/X3.64 escape sequences: CSI SGR styling,
// other CSI sequences, single-character escapes, and OSC control strings. It
// emits a flat event stream — styled text runs, style changes, control
// characters, and recognized sequences — that later tasks interpret (CR/BS/
// erase progress in M10.03, OSC/hyperlink safety in M10.04) and render (M10.06).
//
// The parser is a fixed-location state machine. It preserves state across
// `feed` calls, so an escape sequence split across output chunks is
// reassembled correctly. It never executes a control string: OSC payloads are
// only reported as data (see AGENTS.md §2, Trust). Unknown and truncated
// sequences are handled deterministically. The only allocation is per OSC
// payload (bounded at MAX_OSC_PAYLOAD runes), released at the next feed.
package console

import "base:runtime"

import errs "../errs"

MAX_SGR_PARAMS :: 16
MAX_OSC_PAYLOAD :: 1024

// --- SGR style model ----------------------------------------------------

// Color_Kind tags the form of an SGR color.
Color_Kind :: enum u8 {
	Default, // the terminal's default foreground/background
	Basic, // one of the 16 base colors (index 0..15: 0..7 base, 8..15 bright)
	Palette, // a 256-palette index (0..255)
	RGB, // a 24-bit true color
}

// Color is an SGR color. The zero value is `.Default`. Only the field matching
// `kind` is meaningful: `index` for Basic/Palette, `rgb` for RGB.
Color :: struct {
	kind:  Color_Kind,
	index: u8,
	rgb:   [3]u8,
}

// ANSI_BASIC is the standard xterm/VGA 16-color palette (indices 0..15), used
// for SGR basic (30..37/40..47) and bright (90..97/100..107) colors.
ANSI_BASIC := [16][3]u8 {
	{0x00, 0x00, 0x00}, // 0 black
	{0xcd, 0x00, 0x00}, // 1 red
	{0x00, 0xcd, 0x00}, // 2 green
	{0xcd, 0xcd, 0x00}, // 3 yellow
	{0x00, 0x00, 0xee}, // 4 blue
	{0xcd, 0x00, 0xcd}, // 5 magenta
	{0x00, 0xcd, 0xcd}, // 6 cyan
	{0xe5, 0xe5, 0xe5}, // 7 white
	{0x7f, 0x7f, 0x7f}, // 8 bright black
	{0xff, 0x00, 0x00}, // 9 bright red
	{0x00, 0xff, 0x00}, // 10 bright green
	{0xff, 0xff, 0x00}, // 11 bright yellow
	{0x5c, 0x5c, 0xff}, // 12 bright blue
	{0xff, 0x00, 0xff}, // 13 bright magenta
	{0x00, 0xff, 0xff}, // 14 bright cyan
	{0xff, 0xff, 0xff}, // 15 bright white
}

// color_rgb resolves an SGR color to 24-bit RGB. `has_color` is false for
// `.Default`, which the caller resolves to the terminal's default
// foreground/background. Basic indices clamp to 0..15; palette indices use the
// standard xterm 256-color cube/grayscale.
color_rgb :: proc(color: Color) -> (rgb: [3]u8, has_color: bool) {
	switch color.kind {
	case .Default:
		return {}, false
	case .Basic:
		return ANSI_BASIC[color.index & 15], true
	case .Palette:
		return palette_rgb(color.index), true
	case .RGB:
		return color.rgb, true
	}
	return {}, false
}

// palette_rgb maps a 256-palette index to 24-bit RGB: 0..15 are the basic
// colors, 16..231 the 6×6×6 color cube, and 232..255 a grayscale ramp.
palette_rgb :: proc(index: u8) -> [3]u8 {
	switch {
	case index < 16:
		return ANSI_BASIC[index]
	case index < 232:
		cube := [6]u8{0, 95, 135, 175, 215, 255}
		n := int(index) - 16
		return [3]u8{cube[n / 36], cube[(n % 36) / 6], cube[n % 6]}
	case:
		value := u8(8 + (int(index) - 232) * 10)
		return [3]u8{value, value, value}
	}
}

// Style is the resolved SGR rendering state. The zero value is the SGR reset
// state: default colors, all attributes off.
Style :: struct {
	fg:            Color,
	bg:            Color,
	bold:          bool,
	dim:           bool,
	italic:        bool,
	underline:     bool,
	blink:         bool,
	reverse:       bool,
	hidden:        bool,
	strikethrough: bool,
}

// style_reset returns the SGR reset state (SGR 0).
style_reset :: proc(style: ^Style) {
	style^ = Style{}
}

// apply_sgr interprets an SGR parameter list (the arguments of CSI ... m) and
// updates style in place. Unknown codes and malformed extended-color
// parameters are ignored deterministically; an empty list is SGR 0.
apply_sgr :: proc(style: ^Style, params: []u32) {
	if len(params) == 0 {
		style_reset(style)
		return
	}
	i := 0
	for i < len(params) {
		p := params[i]
		switch {
		case p == 0:
			style_reset(style)
		case p == 1:
			style.bold = true
		case p == 2:
			style.dim = true
		case p == 3:
			style.italic = true
		case p == 4:
			style.underline = true
		case p == 5, p == 6:
			style.blink = true
		case p == 7:
			style.reverse = true
		case p == 8:
			style.hidden = true
		case p == 9:
			style.strikethrough = true
		case p == 21:
			style.bold = false
		case p == 22:
			style.bold = false
			style.dim = false
		case p == 23:
			style.italic = false
		case p == 24:
			style.underline = false
		case p == 25:
			style.blink = false
		case p == 27:
			style.reverse = false
		case p == 28:
			style.hidden = false
		case p == 29:
			style.strikethrough = false
		case p >= 30 && p <= 37:
			style.fg = Color{kind = .Basic, index = u8(p - 30)}
		case p == 38:
			i = sgr_extended_color(&style.fg, params, i)
		case p == 39:
			style.fg = Color{}
		case p >= 40 && p <= 47:
			style.bg = Color{kind = .Basic, index = u8(p - 40)}
		case p == 48:
			i = sgr_extended_color(&style.bg, params, i)
		case p == 49:
			style.bg = Color{}
		case p >= 90 && p <= 97:
			style.fg = Color{kind = .Basic, index = u8(p - 90 + 8)}
		case p >= 100 && p <= 107:
			style.bg = Color{kind = .Basic, index = u8(p - 100 + 8)}
		}
		i += 1
	}
}

// sgr_extended_color consumes the parameters following an SGR 38/48 extended
// color code: "5;n" selects a 256-palette index, "2;r;g;b" selects true color.
// It returns the index of the last consumed parameter; the caller advances
// past it. Missing or unknown sub-parameters leave the color unchanged.
sgr_extended_color :: proc(color: ^Color, params: []u32, at: int) -> int {
	if at + 1 >= len(params) {
		return at
	}
	mode := params[at + 1]
	switch mode {
	case 5:
		if at + 2 >= len(params) {
			return at + 1
		}
		color^ = Color{kind = .Palette, index = u8(min(params[at + 2], 255))}
		return at + 2
	case 2:
		if at + 4 >= len(params) {
			return at + 1
		}
		color^ = Color{
			kind = .RGB,
			rgb = [3]u8{
				u8(min(params[at + 2], 255)),
				u8(min(params[at + 3], 255)),
				u8(min(params[at + 4], 255)),
			},
		}
		return at + 4
	}
	return at + 1
}

// --- Event stream -------------------------------------------------------

// Text_Event is a run of printable runes. `runes` borrows the `input` slice
// passed to the feed call that emitted it; it is valid until the next feed.
Text_Event :: struct {
	runes: []rune,
}

// Style_Event reports the resolved SGR style after a CSI ... m sequence.
Style_Event :: struct {
	style: Style,
}

// Csi_Event reports a recognized, non-SGR CSI sequence (final byte and its
// parameters). M10.03 interprets erase/movement sequences from these events.
// `private` marks a DEC private sequence (CSI ? ...), which the parser
// otherwise drops; the grid uses it for the alternate screen (?1049h/l) and
// cursor visibility (?25h/l).
Csi_Event :: struct {
	final:       rune,
	params:      [MAX_SGR_PARAMS]u32,
	param_count: u8,
	private:     bool,
}

// Control_Event is a C0/C1 control character (other than ESC). `rune` is the
// control's scalar value.
Control_Event :: struct {
	rune: rune,
}

// Osc_Event reports an OSC control string's payload. `payload` is owned by the
// parser (allocated with the parser's allocator) and is valid until the next
// feed call or `parser_destroy`. The parser never executes the payload (M10.04
// owns the safety policy).
Osc_Event :: struct {
	payload: []rune,
}

// Escape_Event reports a single-character escape (ESC + one byte), e.g. DECSC
// (ESC 7), DECRC (ESC 8), IND (ESC D), NEL (ESC E), RI (ESC M). `rune` is the
// byte following ESC.
Escape_Event :: struct {
	rune: rune,
}

Event :: union {
	Text_Event,
	Style_Event,
	Csi_Event,
	Control_Event,
	Osc_Event,
	Escape_Event,
}

// --- Parser -------------------------------------------------------------

Parser_State :: enum u8 {
	Ground,
	Escape, // saw ESC, awaiting the escape body
	Csi, // saw ESC [, collecting parameters
	Osc, // saw ESC ], collecting an OSC payload
}

// Parser is a streaming ANSI state machine over runes. Initialize it with
// `parser_init` and release it with `parser_destroy`. Keep it at one address
// and do not copy it while it is mid-sequence.
Parser :: struct {
	allocator: runtime.Allocator,
	state:     Parser_State,
	style:     Style,
	// CSI parameter accumulation.
	params:      [MAX_SGR_PARAMS]u32,
	param_count: u8,
	value:       u32,
	has_value:   bool,
	private:     bool, // saw the '?' DEC private marker in this CSI sequence
	// OSC payload accumulation.
	osc:          [MAX_OSC_PAYLOAD]rune,
	osc_len:      int,
	osc_overflow: bool,
	st_pending:   bool, // an OSC string ended with ESC (ST); the next '\' is its second byte
	// owned holds the OSC payloads allocated during the current feed; they are
	// released at the start of the next feed and by parser_destroy.
	owned: [dynamic][]rune,
}

// parser_init prepares p. OSC payloads emitted by feed are allocated with
// `allocator` and released at the next feed (or by parser_destroy).
parser_init :: proc(p: ^Parser, allocator := context.allocator) -> errs.Error {
	if p == nil {
		return errs.new(.Invalid_Input, "console: parser is nil", allocator = allocator)
	}
	p^ = {
		allocator = allocator,
		state = .Ground,
		owned = make([dynamic][]rune, allocator),
	}
	return {}
}

// parser_destroy releases the OSC payloads allocated by the last feed.
parser_destroy :: proc(p: ^Parser) {
	if p == nil {
		return
	}
	release_owned(p)
	delete(p.owned)
	p^ = {}
}

// feed consumes input runes and appends events to out, returning how many
// events were written and how many input runes were consumed. A buffer of
// len(input) events always consumes all of input (each event accounts for at
// least one input rune). If out fills first, consumed is less than len(input);
// resume with the remaining runes and a fresh out. Text_Event.runes borrow the
// input slice (valid until the next feed); Osc_Event.payload is owned by the
// parser (valid until the next feed or parser_destroy).
feed :: proc(p: ^Parser, input: []rune, out: []Event) -> (written: int, consumed: int) {
	release_owned(p)
	i := 0
	n := len(input)
	run_start := -1
	for i < n {
		r := input[i]
		switch p.state {
		case .Ground:
			if r == 0x1b {
				if run_start >= 0 {
					if written >= len(out) {
						return written, run_start
					}
					out[written] = Text_Event{runes = input[run_start:i]}
					written += 1
					run_start = -1
				}
				p.state = .Escape
				i += 1
				continue
			}
			if is_control(r) {
				if run_start >= 0 {
					if written >= len(out) {
						return written, run_start
					}
					out[written] = Text_Event{runes = input[run_start:i]}
					written += 1
					run_start = -1
				}
				if written >= len(out) {
					return written, i
				}
				out[written] = Control_Event{rune = r}
				written += 1
				i += 1
				continue
			}
			if run_start < 0 {
				run_start = i
			}
			i += 1
			continue

		case .Escape:
			if p.st_pending {
				p.st_pending = false
				if r == '\\' {
					// ST terminator second byte.
					p.state = .Ground
					i += 1
					continue
				}
				// Not a proper ST; fall through to treat r as a fresh escape body.
			}
			switch r {
			case '[':
				p.state = .Csi
				p.param_count = 0
				p.value = 0
				p.has_value = false
				p.private = false
			case ']':
				p.state = .Osc
				p.osc_len = 0
				p.osc_overflow = false
			case:
				// Single-character escape (ESC + one byte): reported so the
				// grid can handle DECSC/DECRC/IND/NEL/RI.
				if written >= len(out) {
					return written, i
				}
				out[written] = Escape_Event{rune = r}
				written += 1
				p.state = .Ground
			}
			i += 1
			continue

		case .Csi:
			if r >= 0x40 && r <= 0x7e {
				// Final byte: dispatch the sequence.
				if written >= len(out) {
					return written, i
				}
				final := r
				push_param(p)
				p.state = .Ground
				if final == 'm' {
					if p.param_count == 0 {
						p.params[0] = 0
						p.param_count = 1
					}
					apply_sgr(&p.style, p.params[:int(p.param_count)])
					out[written] = Style_Event{style = p.style}
				} else {
					out[written] = Csi_Event{
						final = final,
						params = p.params,
						param_count = p.param_count,
						private = p.private,
					}
				}
				written += 1
				i += 1
				continue
			}
			if r >= 0x30 && r <= 0x3f {
				// Parameter bytes: digits accumulate; ';' and ':' separate;
				// '?' marks a DEC private sequence (reported via Csi_Event.private);
				// the other private markers ('<', '=', '>') are ignored.
				switch {
				case r >= 0x30 && r <= 0x39:
					accumulate_param(p, r)
				case r == ';', r == ':':
					push_param(p)
				case r == '?':
					p.private = true
				}
				i += 1
				continue
			}
			if r >= 0x20 && r <= 0x2f {
				// Intermediate byte: ignored.
				i += 1
				continue
			}
			// Control, ESC, or non-ASCII inside a CSI sequence: cancel it and
			// reprocess the rune in Ground.
			p.state = .Ground
			continue

		case .Osc:
			if r == 0x07 || r == 0x1b {
				// BEL or ESC (ST) terminates the payload. Copy it so later OSC
				// sequences in the same feed do not overwrite it.
				if written >= len(out) {
					return written, i
				}
				payload := make([]rune, p.osc_len, p.allocator)
				copy(payload, p.osc[:p.osc_len])
				append(&p.owned, payload)
				out[written] = Osc_Event{payload = payload}
				written += 1
				if r == 0x1b {
					p.state = .Escape
					p.st_pending = true
				} else {
					p.state = .Ground
				}
				i += 1
				continue
			}
			if !p.osc_overflow {
				if p.osc_len < MAX_OSC_PAYLOAD {
					p.osc[p.osc_len] = r
					p.osc_len += 1
				} else {
					p.osc_overflow = true
				}
			}
			i += 1
			continue
		}
	}

	if run_start >= 0 {
		if written >= len(out) {
			return written, run_start
		}
		out[written] = Text_Event{runes = input[run_start:n]}
		written += 1
		run_start = -1
	}
	return written, i
}

// release_owned frees the OSC payloads allocated during the previous feed.
release_owned :: proc(p: ^Parser) {
	for payload in p.owned {
		delete(payload, p.allocator)
	}
	resize(&p.owned, 0)
}

// is_control reports whether r is a C0 control, DEL, or C1 control rune (that
// is, not printable text and not ESC, which is handled separately).
is_control :: proc(r: rune) -> bool {
	return r < 0x20 || (r >= 0x7f && r <= 0x9f)
}

// accumulate_param appends a decimal digit to the current CSI parameter,
// saturating at 100000 to keep the value bounded.
accumulate_param :: proc(p: ^Parser, r: rune) {
	digit := u32(r - '0')
	if p.has_value {
		if p.value < 100000 {
			p.value = p.value * 10 + digit
		}
	} else {
		p.value = digit
		p.has_value = true
	}
}

// push_param finalizes the current CSI parameter (an empty parameter is 0) and
// appends it to the parameter list, capped at MAX_SGR_PARAMS.
push_param :: proc(p: ^Parser) {
	value := p.value
	if !p.has_value {
		value = 0
	}
	if p.param_count < MAX_SGR_PARAMS {
		p.params[p.param_count] = value
		p.param_count += 1
	}
	p.value = 0
	p.has_value = false
}
