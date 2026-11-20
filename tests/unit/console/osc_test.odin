// Tests for M10.04: OSC control-string parsing, the safety policy, and
// hyperlink tracking through the line buffer.
package console_test

import "core:testing"

import console "hammer:core/console"

// runes_of converts a string to an owned rune slice (caller frees).
runes_of :: proc(s: string) -> []rune {
	out := make([dynamic]rune, context.allocator)
	for r in s {
		append(&out, r)
	}
	return out[:]
}

expect_osc_hyperlink :: proc(t: ^testing.T, o: console.Osc, want_uri: string) {
	link, ok := o.(console.Osc_Hyperlink)
	testing.expect(t, ok, "expected Osc_Hyperlink")
	if ok {
		testing.expectf(t, runes_is(link.uri, want_uri), "hyperlink uri %v want %q", link.uri, want_uri)
	}
}

expect_osc_clipboard :: proc(t: ^testing.T, o: console.Osc, want_sel, want_data: string) {
	clip, ok := o.(console.Osc_Clipboard)
	testing.expect(t, ok, "expected Osc_Clipboard")
	if ok {
		testing.expectf(t, runes_is(clip.selection, want_sel), "clipboard selection %v want %q", clip.selection, want_sel)
		testing.expectf(t, runes_is(clip.data, want_data), "clipboard data %v want %q", clip.data, want_data)
	}
}

expect_link :: proc(t: ^testing.T, link: console.Link, start, length: int, uri: string) {
	testing.expectf(t, link.start == start, "link start %d want %d", link.start, start)
	testing.expectf(t, link.length == length, "link length %d want %d", link.length, length)
	testing.expectf(t, runes_is(link.uri, uri), "link uri %v want %q", link.uri, uri)
}

@(test)
test_osc_parse_title_and_cwd :: proc(t: ^testing.T) {
	r := runes_of("0;my title")
	o := console.osc_parse(r)
	title, ok := o.(console.Osc_Title)
	testing.expect(t, ok && runes_is(title.text, "my title"))
	delete(r)

	r = runes_of("2;another")
	o = console.osc_parse(r)
	title, ok = o.(console.Osc_Title)
	testing.expect(t, ok && runes_is(title.text, "another"))
	delete(r)

	r = runes_of("7;file:///home/user")
	o = console.osc_parse(r)
	cwd, ok2 := o.(console.Osc_Cwd)
	testing.expect(t, ok2 && runes_is(cwd.path, "file:///home/user"))
	delete(r)
}

@(test)
test_osc_parse_hyperlink :: proc(t: ^testing.T) {
	r := runes_of("8;;https://example.com")
	o := console.osc_parse(r)
	expect_osc_hyperlink(t, o, "https://example.com")
	delete(r)

	// Empty URI closes the link.
	r = runes_of("8;;")
	o = console.osc_parse(r)
	expect_osc_hyperlink(t, o, "")
	delete(r)

	// Params (id=...) are skipped; the URI is after the second ';'.
	r = runes_of("8;id=xyz;https://example.com/a;b")
	o = console.osc_parse(r)
	expect_osc_hyperlink(t, o, "https://example.com/a;b")
	delete(r)
}

@(test)
test_osc_parse_clipboard :: proc(t: ^testing.T) {
	r := runes_of("52;c;Zm9v")
	o := console.osc_parse(r)
	expect_osc_clipboard(t, o, "c", "Zm9v")
	delete(r)
}

@(test)
test_osc_parse_ignored :: proc(t: ^testing.T) {
	cases := []string{"", "abc", "1337;foo", "999999999999;x", ";"}
	for c in cases {
		r := runes_of(c)
		o := console.osc_parse(r)
		_, ok := o.(console.Osc_Ignored)
		testing.expectf(t, ok, "expected Osc_Ignored for %q, got %v", c, o)
		delete(r)
	}
}

@(test)
test_control_policy_default_denies_clipboard :: proc(t: ^testing.T) {
	policy := console.Control_Policy{}
	testing.expect(t, !policy.allow_clipboard)
}

@(test)
test_line_buffer_hyperlink :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("\x1b]8;;https://example.com\x1b\\click\x1b]8;;\x1b\\\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "click")
		testing.expect(t, len(lines[0].links) == 1)
		if len(lines[0].links) == 1 {
			expect_link(t, lines[0].links[0], 0, 5, "https://example.com")
		}
	}
}

@(test)
test_line_buffer_hyperlink_surrounding_text :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("see \x1b]8;;http://a\x1b\\this\x1b]8;;\x1b\\ now\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "see this now")
		testing.expect(t, len(lines[0].links) == 1)
		if len(lines[0].links) == 1 {
			expect_link(t, lines[0].links[0], 4, 4, "http://a")
		}
	}
}

@(test)
test_line_buffer_multiple_links :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("\x1b]8;;http://a\x1b\\aa\x1b]8;;\x1b\\b\x1b]8;;http://b\x1b\\bb\x1b]8;;\x1b\\\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "aabbb")
		testing.expect(t, len(lines[0].links) == 2)
		if len(lines[0].links) == 2 {
			expect_link(t, lines[0].links[0], 0, 2, "http://a")
			expect_link(t, lines[0].links[1], 3, 2, "http://b")
		}
	}
}

@(test)
test_line_buffer_hyperlink_closed_at_eol :: proc(t: ^testing.T) {
	// A hyperlink left open at the line feed is closed there.
	lines, _ := collect_lines(transmute([]byte)string("\x1b]8;;http://a\x1b\\one\ntwo\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 2)
	if len(lines) == 2 {
		expect_line_text(t, lines[0], "one")
		testing.expect(t, len(lines[0].links) == 1)
		if len(lines[0].links) == 1 {
			expect_link(t, lines[0].links[0], 0, 3, "http://a")
		}
		// The next line is not part of the link.
		expect_line_text(t, lines[1], "two")
		testing.expect(t, len(lines[1].links) == 0)
	}
}

@(test)
test_line_buffer_clipboard_is_inert :: proc(t: ^testing.T) {
	// OSC 52 clipboard writes produce no text and no links; they are inert.
	lines, _ := collect_lines(transmute([]byte)string("before\x1b]52;c;Zm9v\x07after\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "beforeafter")
		testing.expect(t, len(lines[0].links) == 0)
	}
}

@(test)
test_line_buffer_title_is_inert :: proc(t: ^testing.T) {
	lines, _ := collect_lines(transmute([]byte)string("a\x1b]0;ignored title\x07b\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "ab")
		testing.expect(t, len(lines[0].links) == 0)
	}
}

@(test)
test_line_buffer_hyperlink_with_style :: proc(t: ^testing.T) {
	// A hyperlink span can carry its own style.
	lines, _ := collect_lines(transmute([]byte)string("\x1b[31m\x1b]8;;http://a\x1b\\red\x1b]8;;\x1b\\\x1b[0m\n"))
	defer delete_lines(lines)
	testing.expect(t, len(lines) == 1)
	if len(lines) == 1 {
		expect_line_text(t, lines[0], "red")
		testing.expect(t, len(lines[0].links) == 1)
		if len(lines[0].links) == 1 {
			expect_link(t, lines[0].links[0], 0, 3, "http://a")
		}
		testing.expect(t, len(lines[0].runs) == 1)
		if len(lines[0].runs) == 1 {
			expect_run(t, lines[0].runs[0], 3, basic_fg_style(1))
		}
	}
}
