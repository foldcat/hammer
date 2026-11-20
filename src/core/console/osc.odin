// OSC control-string parsing and safety policy (M10.04).
//
// The ANSI parser (ansi.odin) reports OSC payloads as inert data; it never
// executes them. This file classifies those payloads and applies the safety
// policy that decides what, if anything, they may do (SPECS §12.6):
//
// - Hyperlinks (OSC 8) are data: the URI is recorded so the log window can
//   render a clickable span, but it is never opened or executed here.
// - Clipboard writes (OSC 52) are denied unless Control_Policy.allow_clipboard
//   is explicitly set.
// - Title/icon (OSC 0/1/2) and working-directory (OSC 7) strings are inert.
// - Everything else is ignored.
//
// `osc_parse` is allocation-free: the returned Osc borrows the payload, so the
// payload must stay valid for as long as the result is used (the parser's OSC
// buffer satisfies this within a single feed call).
package console

// Control_Policy gates the effects of OSC control strings. The zero value is
// the safe default: no clipboard writes.
Control_Policy :: struct {
	allow_clipboard: bool, // OSC 52 clipboard writes are permitted
}

// Osc_Title is OSC 0/1/2: a request to set the window/icon title.
Osc_Title :: struct {
	text: []rune,
}

// Osc_Hyperlink is OSC 8: an empty uri closes the current hyperlink; a
// non-empty uri opens one.
Osc_Hyperlink :: struct {
	uri: []rune,
}

// Osc_Clipboard is OSC 52: a clipboard write request. `selection` is the
// clipboard target ("c" for clipboard, "p" for primary, ...) and `data` is the
// base64-encoded content.
Osc_Clipboard :: struct {
	selection: []rune,
	data:      []rune,
}

// Osc_Cwd is OSC 7: a working-directory announcement.
Osc_Cwd :: struct {
	path: []rune,
}

// Osc_Ignored is any unrecognized or malformed OSC control string.
Osc_Ignored :: struct {}

Osc :: union {
	Osc_Title,
	Osc_Hyperlink,
	Osc_Clipboard,
	Osc_Cwd,
	Osc_Ignored,
}

// osc_parse classifies an OSC payload. The payload is the text between the
// OSC introducer (ESC ]) and its terminator, beginning with a decimal command
// number. The result borrows payload.
osc_parse :: proc(payload: []rune) -> Osc {
	command, end := osc_command(payload)
	if command < 0 {
		return Osc_Ignored{}
	}
	args := payload[end:]
	switch command {
	case 0, 1, 2:
		return Osc_Title{text = args}
	case 7:
		return Osc_Cwd{path = args}
	case 8:
		return Osc_Hyperlink{uri = osc_hyperlink_uri(args)}
	case 52:
		selection, data := osc_split(args)
		return Osc_Clipboard{selection = selection, data = data}
	}
	return Osc_Ignored{}
}

// osc_command reads the leading decimal command number, returning it and the
// index just past the separating ';' (or len(payload) if absent). It returns
// -1 when there is no command number.
osc_command :: proc(payload: []rune) -> (command: int, end: int) {
	i := 0
	value := 0
	for i < len(payload) && payload[i] >= '0' && payload[i] <= '9' {
		value = value * 10 + int(payload[i] - '0')
		if value > 999 {
			return -1, 0
		}
		i += 1
	}
	if i == 0 {
		return -1, 0
	}
	if i < len(payload) && payload[i] == ';' {
		i += 1
	}
	return value, i
}

// osc_hyperlink_uri extracts the URI from OSC 8 arguments ("params;URI"). The
// URI is everything after the first ';'; if there is none, the whole argument
// is treated as the URI.
osc_hyperlink_uri :: proc(args: []rune) -> []rune {
	for i in 0 ..< len(args) {
		if args[i] == ';' {
			return args[i + 1:]
		}
	}
	return args
}

// osc_split splits "left;right" at the first ';'. Without one, the whole input
// is the left part and the right part is empty.
osc_split :: proc(args: []rune) -> (left, right: []rune) {
	for i in 0 ..< len(args) {
		if args[i] == ';' {
			return args[:i], args[i + 1:]
		}
	}
	return args, {}
}
