package shaping

import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

import errs "../../core/errs"
import ft "../freetype"
import glyphcache "../glyphcache"
import hb "../harfbuzz"
import icu "../icu"

MAX_SHAPE_BYTES :: 1 << 20
MAX_FONTS :: 8

Byte_Range :: struct {
	start: int,
	end:   int,
}

Codepoint :: struct {
	r:     rune,
	start: int,
	end:   int,
}

Encoded :: struct {
	utf16:         [dynamic]icu.UChar,
	utf16_to_byte: [dynamic]int,
	codepoints:    [dynamic]Codepoint,
}

Segment :: struct {
	range:      Byte_Range,
	font_index: int
}

shape :: proc(text: string, fonts: []Font, options: Options, allocator := context.allocator) -> (Text, errs.Error) {
	result := Text{
		runs = make([dynamic]Run, allocator),
		missing = make([dynamic]Missing_Glyph, allocator),
	}
	if len(text) == 0 {
		return result, errs.Error{}
	}
	if len(text) > MAX_SHAPE_BYTES {
		text_destroy_on_error(&result)
		return {}, errs.new(.Resource_Limit, "shaping input exceeds the one-line budget", allocator = allocator)
	}
	if !utf8.valid_string(text) || strings.contains(text, "\n") || strings.contains(text, "\r") {
		text_destroy_on_error(&result)
		return {}, errs.new(.Invalid_Input, "shaping requires one valid UTF-8 line", allocator = allocator)
	}
	if len(fonts) == 0 || len(fonts) > MAX_FONTS || options.pixel_size == 0 || options.pixel_size > glyphcache.MAX_PIXEL_SIZE || int(options.variation_count) > glyphcache.MAX_VARIATIONS {
		text_destroy_on_error(&result)
		return {}, errs.new(.Invalid_Input, "invalid shaping fonts, pixel size, or variations", allocator = allocator)
	}
	for font in fonts {
		if font.font_id == 0 || font.face_index < 0 || font.native == nil {
			text_destroy_on_error(&result)
			return {}, errs.new(.Invalid_Input, "invalid native font in shaping input", allocator = allocator)
		}
	}

	encoded := encode(text, allocator)
	defer encoded_destroy(&encoded)
	bidi := icu.ubidi_open()
	if bidi == nil {
		text_destroy_on_error(&result)
		return {}, errs.new(.Resource_Limit, "ICU could not allocate bidi state", allocator = allocator)
	}
	defer icu.ubidi_close(bidi)
	status := icu.ZERO_ERROR
	level := icu.DEFAULT_LTR
	if options.direction == .LTR {
		level = 0
	} else if options.direction == .RTL {
		level = 1
	}
	icu.ubidi_setPara(bidi, raw_data(encoded.utf16[:]), i32(len(encoded.utf16)), level, nil, &status)
	if !icu.success(status) {
		text_destroy_on_error(&result)
		return {}, errs.newf(.Internal, "ICU bidi setup failed: %d", status, allocator = allocator)
	}
	run_count := icu.ubidi_countRuns(bidi, &status)
	if !icu.success(status) || run_count < 0 {
		text_destroy_on_error(&result)
		return {}, errs.newf(.Internal, "ICU bidi run counting failed: %d", status, allocator = allocator)
	}
	graphemes, grapheme_err := grapheme_ranges(encoded, allocator)
	if !errs.ok(grapheme_err) {
		text_destroy_on_error(&result)
		return {}, grapheme_err
	}
	defer delete(graphemes)

	for run_index in 0 ..< run_count {
		logical_start, logical_length: i32
		direction := icu.ubidi_getVisualRun(bidi, run_index, &logical_start, &logical_length)
		if logical_start < 0 || logical_length <= 0 || int(logical_start + logical_length) > len(encoded.utf16) {
			text_destroy_on_error(&result)
			return {}, errs.new(.Internal, "ICU returned an invalid bidi run", allocator = allocator)
		}
		byte_run := Byte_Range{
			start = encoded.utf16_to_byte[logical_start],
			end = encoded.utf16_to_byte[logical_start + logical_length],
		}
		run_direction := Direction.LTR
		if direction == .RTL {
			run_direction = .RTL
		}
		if err := shape_visual_run(&result, text, byte_run, run_direction, graphemes[:], encoded.codepoints[:], fonts, options, allocator); !errs.ok(err) {
			text_destroy_on_error(&result)
			return {}, err
		}
	}
	return result, errs.Error{}
}

encode :: proc(text: string, allocator := context.allocator) -> Encoded {
	result := Encoded{
		utf16 = make([dynamic]icu.UChar, allocator),
		utf16_to_byte = make([dynamic]int, allocator),
		codepoints = make([dynamic]Codepoint, allocator),
	}
	for byte_offset := 0; byte_offset < len(text); {
		r, width := utf8.decode_rune_in_string(text[byte_offset:])
		start := byte_offset
		units := 1
		if r > 0xffff {
			units = 2
		}
		for _ in 0 ..< units {
			append(&result.utf16_to_byte, start)
		}
		if units == 1 {
			append(&result.utf16, icu.UChar(r))
		} else {
			first, second := utf16.encode_surrogate_pair(r)
			append(&result.utf16, icu.UChar(first), icu.UChar(second))
		}
		append(&result.codepoints, Codepoint{r = r, start = start, end = start + width})
		byte_offset += width
	}
	append(&result.utf16_to_byte, len(text))
	return result
}

encoded_destroy :: proc(encoded: ^Encoded) {
	delete(encoded.utf16)
	delete(encoded.utf16_to_byte)
	delete(encoded.codepoints)
}

grapheme_ranges :: proc(encoded: Encoded, allocator := context.allocator) -> ([dynamic]Byte_Range, errs.Error) {
	ranges := make([dynamic]Byte_Range, allocator)
	status := icu.ZERO_ERROR
	iterator := icu.ubrk_open(.Character, "", raw_data(encoded.utf16[:]), i32(len(encoded.utf16)), &status)
	if !icu.success(status) || iterator == nil {
		delete(ranges)
		return nil, errs.newf(.Internal, "ICU grapheme iterator failed: %d", status, allocator = allocator)
	}
	defer icu.ubrk_close(iterator)
	start := icu.ubrk_first(iterator)
	for {
		end := icu.ubrk_next(iterator)
		if end == icu.DONE {
			break
		}
		if start < 0 || end <= start || int(end) >= len(encoded.utf16_to_byte) {
			delete(ranges)
			return nil, errs.new(.Internal, "ICU returned an invalid grapheme boundary", allocator = allocator)
		}
		append(&ranges, Byte_Range{start = encoded.utf16_to_byte[start], end = encoded.utf16_to_byte[end]})
		start = end
	}
	return ranges, errs.Error{}
}

shape_visual_run :: proc(
	result: ^Text,
	text: string,
	byte_run: Byte_Range,
	direction: Direction,
	graphemes: []Byte_Range,
	codepoints: []Codepoint,
	fonts: []Font,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	segments := make([dynamic]Segment, allocator)
	defer delete(segments)
	current_start := -1
	current_font := -1
	for cluster in graphemes {
		if cluster.start < byte_run.start || cluster.end > byte_run.end {
			continue
		}
		font_index := choose_font(result, codepoints, cluster, fonts, allocator)
		if current_font < 0 {
			current_start = cluster.start
			current_font = font_index
		} else if font_index != current_font {
			append(&segments, Segment{range = {start = current_start, end = cluster.start}, font_index = current_font})
			current_start = cluster.start
			current_font = font_index
		}
	}
	if current_font >= 0 {
		append(&segments, Segment{range = {start = current_start, end = byte_run.end}, font_index = current_font})
	}
	if direction == .RTL {
		for index := len(segments) - 1; index >= 0; index -= 1 {
			if err := shape_segment(result, text, segments[index], direction, graphemes, fonts, options, allocator); !errs.ok(err) {
				return err
			}
		}
	} else {
		for segment in segments {
			if err := shape_segment(result, text, segment, direction, graphemes, fonts, options, allocator); !errs.ok(err) {
				return err
			}
		}
	}
	return errs.Error{}
}

choose_font :: proc(result: ^Text, codepoints: []Codepoint, cluster: Byte_Range, fonts: []Font, allocator := context.allocator) -> int {
	for font, index in fonts {
		supported := true
		for codepoint in codepoints {
			if codepoint.start >= cluster.start && codepoint.end <= cluster.end && ft.FT_Get_Char_Index(ft.Face(font.native), ft.ULong(codepoint.r)) == 0 {
				supported = false
				break
			}
		}
		if supported {
			return index
		}
	}
	for codepoint in codepoints {
		if codepoint.start >= cluster.start && codepoint.end <= cluster.end && ft.FT_Get_Char_Index(ft.Face(fonts[0].native), ft.ULong(codepoint.r)) == 0 {
			append(&result.missing, Missing_Glyph{font_id = fonts[0].font_id, codepoint = codepoint.r, source_offset = codepoint.start})
		}
	}
	return 0
}

shape_segment :: proc(result: ^Text, text: string, segment: Segment, direction: Direction, graphemes: []Byte_Range, fonts: []Font, options: Options, allocator := context.allocator) -> errs.Error {
	font := fonts[segment.font_index]
	face := ft.Face(font.native)
	if ft_result := ft.FT_Set_Pixel_Sizes(face, 0, options.pixel_size); ft_result != 0 {
		return errs.newf(.IO, "FreeType sizing for shaping failed: %d", ft_result, allocator = allocator)
	}
	hb_font := hb.hb_ft_font_create_referenced(face)
	if hb_font == nil {
		return errs.new(.Resource_Limit, "HarfBuzz could not create a font", allocator = allocator)
	}
	defer hb.hb_font_destroy(hb_font)
	variations: [glyphcache.MAX_VARIATIONS]hb.Variation
	for index in 0 ..< int(options.variation_count) {
		variations[index] = {tag = options.variations[index].tag, value = options.variations[index].value}
	}
	hb.hb_font_set_variations(hb_font, raw_data(variations[:]), u32(options.variation_count))
	buffer := hb.hb_buffer_create()
	if buffer == nil {
		return errs.new(.Resource_Limit, "HarfBuzz could not allocate a buffer", allocator = allocator)
	}
	defer hb.hb_buffer_destroy(buffer)
	hb_direction := hb.Direction.LTR
	if direction == .RTL {
		hb_direction = .RTL
	}
	hb.hb_buffer_set_direction(buffer, hb_direction)
	hb.hb_buffer_add_utf8(buffer, raw_data(text), i32(len(text)), u32(segment.range.start), i32(segment.range.end - segment.range.start))
	hb.hb_buffer_guess_segment_properties(buffer)
	features: [2]hb.Feature
	feature_count := 0
	if !options.ligatures {
		features[0] = {tag = hb.hb_tag_from_string("liga", -1), start = 0, end = max(u32)}
		features[1] = {tag = hb.hb_tag_from_string("clig", -1), start = 0, end = max(u32)}
		feature_count = 2
	}
	hb.hb_shape(hb_font, buffer, raw_data(features[:]), u32(feature_count))
	info_count, position_count: u32
	infos := hb.hb_buffer_get_glyph_infos(buffer, &info_count)
	positions := hb.hb_buffer_get_glyph_positions(buffer, &position_count)
	if info_count != position_count || (info_count > 0 && (infos == nil || positions == nil)) {
		return errs.new(.Internal, "HarfBuzz returned inconsistent glyph arrays", allocator = allocator)
	}
	if info_count == 0 {
		return errs.Error{}
	}

	run := Run{
		source_start = segment.range.start,
		source_end = segment.range.end,
		direction = direction,
		font_id = font.font_id,
		face_index = font.face_index,
		pixel_size = options.pixel_size,
		variation_count = options.variation_count,
		variations = options.variations,
		glyphs = make([dynamic]Glyph, 0, info_count, allocator),
	}
	pen_x := result.total_advance
	for index in 0 ..< int(info_count) {
		info := infos[index]
		position := positions[index]
		cluster := int(info.cluster)
		if cluster < segment.range.start || cluster >= segment.range.end {
			delete(run.glyphs)
			return errs.new(.Internal, "HarfBuzz returned an out-of-range source cluster", allocator = allocator)
		}
		if info.codepoint == 0 {
			diagnose_zero_glyph(result, font.font_id, cluster)
		}
		append(&run.glyphs, Glyph{
			glyph_id = info.codepoint,
			cluster = cluster,
			x = pen_x + position.x_offset,
			y = position.y_offset,
			x_advance = position.x_advance,
			y_advance = position.y_advance,
			x_offset = position.x_offset,
			y_offset = position.y_offset,
		})
		pen_x += position.x_advance
	}
	run.advance = pen_x - result.total_advance
	if err := build_clusters(&run, segment, direction, graphemes, allocator); !errs.ok(err) {
		delete(run.glyphs)
		delete(run.clusters)
		return err
	}
	result.total_advance = pen_x
	append(&result.runs, run)
	return errs.Error{}
}

build_clusters :: proc(run: ^Run, segment: Segment, direction: Direction, graphemes: []Byte_Range, allocator := context.allocator) -> errs.Error {
	first := 0
	for first < len(graphemes) && graphemes[first].end <= segment.range.start {
		first += 1
	}
	last := first
	for last < len(graphemes) && graphemes[last].start < segment.range.end {
		last += 1
	}
	if first == last {
		return errs.new(.Internal, "shaping found no graphemes for a nonempty run", allocator = allocator)
	}
	run.clusters = make([dynamic]Cluster, 0, last - first, allocator)

	step := 1
	grapheme_index := first
	if direction == .RTL {
		step = -1
		grapheme_index = last - 1
	}
	glyph_index := 0
	for glyph_index < len(run.glyphs) {
		glyph_cluster := run.glyphs[glyph_index].cluster
		group_x := run.glyphs[glyph_index].x - run.glyphs[glyph_index].x_offset
		group_advance := i32(0)
		for glyph_index < len(run.glyphs) && run.glyphs[glyph_index].cluster == glyph_cluster {
			group_advance += run.glyphs[glyph_index].x_advance
			glyph_index += 1
		}
		if grapheme_index < first || grapheme_index >= last || graphemes[grapheme_index].start != glyph_cluster {
			return errs.new(.Internal, "HarfBuzz cluster does not match its grapheme", allocator = allocator)
		}

		group_grapheme := grapheme_index
		grapheme_count := 0
		for {
			grapheme_count += 1
			grapheme_index += step
			if grapheme_index < first || grapheme_index >= last {
				break
			}
			if glyph_index < len(run.glyphs) && graphemes[grapheme_index].start == run.glyphs[glyph_index].cluster {
				break
			}
		}
		for local_index in 0 ..< grapheme_count {
			grapheme := graphemes[group_grapheme + local_index * step]
			x := group_x + i32(i64(group_advance) * i64(local_index) / i64(grapheme_count))
			next_x := group_x + i32(i64(group_advance) * i64(local_index + 1) / i64(grapheme_count))
			append(&run.clusters, Cluster{
				source_start = grapheme.start,
				source_end = grapheme.end,
				x = x,
				advance = next_x - x,
			})
		}
	}
	if grapheme_index >= first && grapheme_index < last {
		return errs.new(.Internal, "HarfBuzz omitted a grapheme cluster", allocator = allocator)
	}
	return {}
}

diagnose_zero_glyph :: proc(result: ^Text, font_id: u64, cluster: int) {
	for diagnostic in result.missing {
		if diagnostic.font_id == font_id && diagnostic.source_offset == cluster {
			return
		}
	}
	append(&result.missing, Missing_Glyph{font_id = font_id, source_offset = cluster})
}

text_destroy_on_error :: proc(text: ^Text) {
	destroy(text)
}
