#+build linux

package shaping

import "core:unicode/utf8"

import errs "../../core/errs"

DEFAULT_VISIBLE_BYTES :: 64 * 1024
VISIBLE_LOOKAHEAD_BYTES :: 4096

visible_next :: proc(
	line: string,
	cursor: ^Measurement,
	fonts: []Font,
	options: Options,
	max_bytes := DEFAULT_VISIBLE_BYTES,
	allocator := context.allocator,
) -> (Visible, errs.Error) {
	if cursor == nil || max_bytes <= 0 || max_bytes > MAX_SHAPE_BYTES {
		return {}, errs.new(.Invalid_Input, "shaping: invalid visible-range cursor or byte budget", allocator = allocator)
	}
	if cursor.offset < 0 || cursor.offset > len(line) || cursor.advance < 0 {
		return {}, errs.new(.Invalid_Input, "shaping: invalid incremental measurement state", allocator = allocator)
	}

	start := cursor.offset
	shape_end := len(line)
	remaining := len(line) - start
	if remaining > max_bytes {
		read_end := min(len(line), start + max_bytes + VISIBLE_LOOKAHEAD_BYTES)
		adjustments := 0
		for !utf8.valid_string(line[start:read_end]) && read_end > start && adjustments < 3 {
			read_end -= 1
			adjustments += 1
		}
		encoded := encode(line[start:read_end], allocator)
		defer encoded_destroy(&encoded)
		graphemes, grapheme_err := grapheme_ranges(encoded, allocator)
		if !errs.ok(grapheme_err) {
			return {}, grapheme_err
		}
		defer delete(graphemes)
		safe_bytes := 0
		for grapheme in graphemes {
			if grapheme.end > max_bytes {
				break
			}
			safe_bytes = grapheme.end
		}
		if safe_bytes == 0 {
			return {}, errs.new(.Resource_Limit, "shaping: first grapheme exceeds the visible-range byte budget", allocator = allocator)
		}
		shape_end = start + safe_bytes
	}

	shaped, shape_err := shape(line[start:shape_end], fonts, options, allocator)
	if !errs.ok(shape_err) {
		return {}, shape_err
	}
	if shaped.total_advance < 0 || cursor.advance > max(i64) - i64(shaped.total_advance) {
		destroy(&shaped)
		return {}, errs.new(.Resource_Limit, "shaping: incremental line advance overflow", allocator = allocator)
	}
	rebase_visible_text(&shaped, start)
	segmented := cursor.segmented || start > 0 || shape_end < len(line)
	result := Visible{
		text = shaped,
		start = start,
		end = shape_end,
		done = shape_end == len(line),
		segmented = segmented,
	}
	cursor.offset = shape_end
	cursor.advance += i64(shaped.total_advance)
	cursor.segmented = segmented
	return result, errs.Error{}
}

rebase_visible_text :: proc(text: ^Text, offset: int) {
	for &run in text.runs {
		run.source_start += offset
		run.source_end += offset
		for &glyph in run.glyphs {
			glyph.cluster += offset
		}
		for &cluster in run.clusters {
			cluster.source_start += offset
			cluster.source_end += offset
		}
	}
	for &diagnostic in text.missing {
		diagnostic.source_offset += offset
	}
}
