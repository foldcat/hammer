#+build windows

package shaping

import "core:math"
import "core:strings"
import "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

import errs "../../core/errs"
import dw "../directwrite"
import glyphcache "../glyphcache"
import icu "../icu"

MAX_SHAPE_BYTES :: 1 << 20
MAX_MISSING_DIAGNOSTICS :: 64
E_INVALIDARG :: windows.HRESULT(-2147024809)
E_NOINTERFACE :: windows.HRESULT(-2147467262)

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
	font_index: int,
	script:     dw.Script_Analysis,
}

Script_Range :: struct {
	position: u32,
	length:   u32,
	analysis: dw.Script_Analysis,
}

Analysis_Source_Impl :: struct {
	base: dw.Text_Analysis_Source,
	text: []u16,
}

Analysis_Sink_Impl :: struct {
	base:        dw.Text_Analysis_Sink,
	ranges:      []Script_Range,
	count:       int,
	text_length: u32,
	failed:      bool,
}

source_vtable := dw.Text_Analysis_Source_VTable{
	query_interface = source_query_interface,
	add_ref = analysis_add_ref,
	release = analysis_release,
	get_text_at_position = source_text_at_position,
	get_text_before_position = source_text_before_position,
	get_paragraph_reading_direction = source_reading_direction,
	get_locale_name = source_locale_name,
	get_number_substitution = source_number_substitution,
}

sink_vtable := dw.Text_Analysis_Sink_VTable{
	query_interface = sink_query_interface,
	add_ref = analysis_add_ref,
	release = analysis_release,
	set_script_analysis = sink_set_script_analysis,
}

shape :: proc(text: string, fonts: []Font, options: Options, allocator := context.allocator) -> (Text, errs.Error) {
	result := Text{
		runs = make([dynamic]Run, allocator),
		missing = make([dynamic]Missing_Glyph, allocator),
	}
	if len(text) == 0 {
		return result, {}
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
	graphemes, grapheme_err := grapheme_ranges(encoded, allocator)
	if !errs.ok(grapheme_err) {
		text_destroy_on_error(&result)
		return {}, grapheme_err
	}
	defer delete(graphemes)
	scripts, script_err := analyze_scripts(encoded, fonts[0], allocator)
	if !errs.ok(script_err) {
		text_destroy_on_error(&result)
		return {}, script_err
	}
	defer delete(scripts)

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
		if err := shape_visual_run(&result, text, byte_run, run_direction, graphemes[:], encoded, fonts, scripts[:], options, allocator); !errs.ok(err) {
			text_destroy_on_error(&result)
			return {}, err
		}
	}
	return result, {}
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
	return ranges, {}
}

analyze_scripts :: proc(encoded: Encoded, font: Font, allocator := context.allocator) -> ([]Script_Range, errs.Error) {
	native := cast(^dw.Native_Face)font.native
	if native.analyzer == nil {
		return nil, errs.new(.Invalid_Input, "DirectWrite shaping requires a text analyzer", allocator = allocator)
	}
	ranges := make([]Script_Range, len(encoded.utf16), allocator)
	source := Analysis_Source_Impl{text = encoded.utf16[:]}
	source.base.vtable = &source_vtable
	sink := Analysis_Sink_Impl{ranges = ranges, text_length = u32(len(encoded.utf16))}
	sink.base.vtable = &sink_vtable
	status := native.analyzer.vtable.analyze_script(native.analyzer, &source.base, 0, u32(len(encoded.utf16)), &sink.base)
	if !dw.succeeded(status) || sink.failed {
		delete(ranges)
		return nil, errs.newf(.Internal, "DirectWrite script analysis failed: %d", i32(status), allocator = allocator)
	}
	expected: u32 = 0
	for script in ranges[:sink.count] {
		if script.position != expected || script.length == 0 || script.length > u32(len(encoded.utf16)) - expected {
			delete(ranges)
			return nil, errs.new(.Internal, "DirectWrite returned inconsistent script ranges", allocator = allocator)
		}
		expected += script.length
	}
	if expected != u32(len(encoded.utf16)) {
		delete(ranges)
		return nil, errs.new(.Internal, "DirectWrite script analysis did not cover the input", allocator = allocator)
	}
	return ranges[:sink.count], {}
}

shape_visual_run :: proc(
	result: ^Text,
	text: string,
	byte_run: Byte_Range,
	direction: Direction,
	graphemes: []Byte_Range,
	encoded: Encoded,
	fonts: []Font,
	scripts: []Script_Range,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	segments := make([dynamic]Segment, allocator)
	defer delete(segments)
	current_start := -1
	current_font := -1
	current_script := -1
	for cluster in graphemes {
		if cluster.start < byte_run.start || cluster.end > byte_run.end {
			continue
		}
		font_index := choose_font(result, encoded.codepoints[:], cluster, fonts)
		unit := utf16_index(encoded, cluster.start)
		script_index := script_index_at(scripts, unit)
		if script_index < 0 {
			return errs.new(.Internal, "DirectWrite could not map a grapheme to its script", allocator = allocator)
		}
		if current_font < 0 {
			current_start = cluster.start
			current_font = font_index
			current_script = script_index
		} else if font_index != current_font || script_index != current_script {
			append(&segments, Segment{range = {start = current_start, end = cluster.start}, font_index = current_font, script = scripts[current_script].analysis})
			current_start = cluster.start
			current_font = font_index
			current_script = script_index
		}
	}
	if current_font >= 0 {
		append(&segments, Segment{range = {start = current_start, end = byte_run.end}, font_index = current_font, script = scripts[current_script].analysis})
	}
	if direction == .RTL {
		for index := len(segments) - 1; index >= 0; index -= 1 {
			if err := shape_segment(result, text, segments[index], direction, graphemes, encoded, fonts, options, allocator); !errs.ok(err) {
				return err
			}
		}
	} else {
		for segment in segments {
			if err := shape_segment(result, text, segment, direction, graphemes, encoded, fonts, options, allocator); !errs.ok(err) {
				return err
			}
		}
	}
	return {}
}

utf16_index :: proc(encoded: Encoded, byte_offset: int) -> int {
	low, high := 0, len(encoded.utf16_to_byte)
	for low < high {
		middle := low + (high - low) / 2
		if encoded.utf16_to_byte[middle] < byte_offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

script_index_at :: proc(scripts: []Script_Range, unit: int) -> int {
	for script, index in scripts {
		if unit >= int(script.position) && unit < int(script.position + script.length) {
			return index
		}
	}
	return -1
}

choose_font :: proc(result: ^Text, codepoints: []Codepoint, cluster: Byte_Range, fonts: []Font) -> int {
	cluster_points := codepoints_for_grapheme(codepoints, cluster)
	if emoji_presentation_cluster(cluster_points) && len(fonts) > 1 && font_covers(cluster_points, fonts[1]) {
		return 1
	}
	for font, index in fonts {
		if font_covers(cluster_points, font) {
			return index
		}
	}
	for codepoint in cluster_points {
		if len(result.missing) >= MAX_MISSING_DIAGNOSTICS {
			break
		}
		if codepoint.r >= 0xfe00 && codepoint.r <= 0xfe0f {
			continue
		}
		if !font_covers([]Codepoint{codepoint}, fonts[0]) {
			append(&result.missing, Missing_Glyph{font_id = fonts[0].font_id, codepoint = codepoint.r, source_offset = codepoint.start})
		}
	}
	return 0
}

font_covers :: proc(codepoints: []Codepoint, font: Font) -> bool {
	native := cast(^dw.Native_Face)font.native
	for codepoint in codepoints {
		if codepoint.r >= 0xfe00 && codepoint.r <= 0xfe0f {
			continue
		}
		point := [1]u32{u32(codepoint.r)}
		index := [1]u16{}
		status := native.face.vtable.get_glyph_indices(native.face, raw_data(point[:]), 1, raw_data(index[:]))
		if !dw.succeeded(status) || index[0] == 0 {
			return false
		}
	}
	return true
}

emoji_presentation_cluster :: proc(codepoints: []Codepoint) -> bool {
	for codepoint in codepoints {
		if codepoint.r == 0x200d || codepoint.r == 0xfe0f || icu.u_hasBinaryProperty(icu.Char32(codepoint.r), icu.EMOJI_PRESENTATION) != 0 {
			return true
		}
	}
	return false
}

codepoints_for_grapheme :: proc(codepoints: []Codepoint, cluster: Byte_Range) -> []Codepoint {
	low, high := 0, len(codepoints)
	for low < high {
		middle := low + (high - low) / 2
		if codepoints[middle].start < cluster.start {
			low = middle + 1
		} else {
			high = middle
		}
	}
	end := low
	for end < len(codepoints) && codepoints[end].end <= cluster.end {
		end += 1
	}
	return codepoints[low:end]
}

shape_segment :: proc(
	result: ^Text,
	text: string,
	segment: Segment,
	direction: Direction,
	graphemes: []Byte_Range,
	encoded: Encoded,
	fonts: []Font,
	options: Options,
	allocator := context.allocator,
) -> errs.Error {
	font := fonts[segment.font_index]
	native := cast(^dw.Native_Face)font.native
	script := segment.script
	unit_start := utf16_index(encoded, segment.range.start)
	unit_end := utf16_index(encoded, segment.range.end)
	if unit_start < 0 || unit_end <= unit_start || unit_end > len(encoded.utf16) {
		return errs.new(.Internal, "DirectWrite received an invalid UTF-16 segment", allocator = allocator)
	}
	text_length := unit_end - unit_start
	is_rtl := windows.BOOL(direction == .RTL)
	features := [5]dw.Font_Feature{
		{name = .Standard_Ligatures, parameter = 0},
		{name = .Contextual_Ligatures, parameter = 0},
		{name = .Discretionary_Ligatures, parameter = 0},
		{name = .Historical_Ligatures, parameter = 0},
		{name = .Contextual_Alternates, parameter = 0},
	}
	typography := dw.Typographic_Features{features = raw_data(features[:]), feature_count = len(features)}
	feature_list := [1]^dw.Typographic_Features{&typography}
	feature_lengths := [1]u32{u32(text_length)}
	feature_count := u32(0)
	if !options.ligatures {
		feature_count = 1
	}

	max_glyphs := min(65535, text_length * 3 / 2 + 16)
	for attempt := 0; attempt < 6; attempt += 1 {
		cluster_map := make([]u16, text_length, allocator)
		text_properties := make([]dw.Shaping_Text_Properties, text_length, allocator)
		indices := make([]u16, max_glyphs, allocator)
		glyph_properties := make([]dw.Shaping_Glyph_Properties, max_glyphs, allocator)
		defer delete(cluster_map, allocator)
		defer delete(text_properties, allocator)
		defer delete(indices, allocator)
		defer delete(glyph_properties, allocator)
		glyph_count: u32
		status := native.analyzer.vtable.get_glyphs(
			native.analyzer,
			raw_data(encoded.utf16[unit_start:unit_end]),
			u32(text_length),
			native.face,
			false,
			is_rtl,
			&script,
			nil,
			nil,
			raw_data(feature_list[:]),
			raw_data(feature_lengths[:]),
			feature_count,
			u32(max_glyphs),
			raw_data(cluster_map),
			raw_data(text_properties),
			raw_data(indices),
			raw_data(glyph_properties),
			&glyph_count,
		)
		if status == dw.E_NOT_SUFFICIENT_BUFFER && max_glyphs < 65535 {
			max_glyphs = min(65535, max_glyphs * 2)
			continue
		}
		if !dw.succeeded(status) || glyph_count == 0 || int(glyph_count) > max_glyphs {
			return errs.newf(.Internal, "DirectWrite glyph shaping failed: %d", i32(status), allocator = allocator)
		}

		glyph_clusters := make([]int, int(glyph_count), allocator)
		defer delete(glyph_clusters, allocator)
		for &cluster in glyph_clusters {
			cluster = -1
		}
		for unit in 0 ..< text_length {
			glyph_index := int(cluster_map[unit])
			if glyph_index >= int(glyph_count) {
				return errs.new(.Internal, "DirectWrite returned an out-of-range glyph cluster", allocator = allocator)
			}
			if glyph_clusters[glyph_index] < 0 {
				glyph_clusters[glyph_index] = encoded.utf16_to_byte[unit_start + unit]
			}
		}
		if direction == .RTL {
			next_cluster := segment.range.start
			for index := int(glyph_count) - 1; index >= 0; index -= 1 {
				if glyph_clusters[index] < 0 {
					glyph_clusters[index] = next_cluster
				} else {
					next_cluster = glyph_clusters[index]
				}
			}
		} else {
			previous_cluster := segment.range.start
			for index in 0 ..< int(glyph_count) {
				if glyph_clusters[index] < 0 {
					glyph_clusters[index] = previous_cluster
				} else {
					previous_cluster = glyph_clusters[index]
				}
			}
		}
		advances := make([]f32, int(glyph_count), allocator)
		offsets := make([]dw.Glyph_Offset, int(glyph_count), allocator)
		defer delete(advances, allocator)
		defer delete(offsets, allocator)
		status = native.analyzer.vtable.get_glyph_placements(
			native.analyzer,
			raw_data(encoded.utf16[unit_start:unit_end]),
			raw_data(cluster_map),
			raw_data(text_properties),
			u32(text_length),
			raw_data(indices),
			raw_data(glyph_properties),
			glyph_count,
			native.face,
			f32(options.pixel_size),
			false,
			is_rtl,
			&script,
			nil,
			raw_data(feature_list[:]),
			raw_data(feature_lengths[:]),
			feature_count,
			raw_data(advances),
			raw_data(offsets),
		)
		if !dw.succeeded(status) {
			return errs.newf(.Internal, "DirectWrite glyph placement failed: %d", i32(status), allocator = allocator)
		}

		run := Run{
			source_start = segment.range.start,
			source_end = segment.range.end,
			direction = direction,
			font_id = font.font_id,
			face_index = font.face_index,
			pixel_size = options.pixel_size,
			render_mode = .Normal,
			variation_count = options.variation_count,
			variations = options.variations,
			glyphs = make([dynamic]Glyph, 0, glyph_count, allocator),
		}
		pen_x := result.total_advance
		for index in 0 ..< int(glyph_count) {
			source_index := index
			if direction == .RTL {
				source_index = int(glyph_count) - 1 - index
			}
			if glyph_clusters[source_index] < 0 {
				delete(run.glyphs)
				return errs.new(.Internal, "DirectWrite returned a glyph without a source cluster", allocator = allocator)
			}
			advance, advance_ok := fixed_26_6(advances[source_index])
			x_offset, x_ok := fixed_26_6(offsets[source_index].advance_offset)
			y_offset, y_ok := fixed_26_6(offsets[source_index].ascender_offset)
			if !advance_ok || !x_ok || !y_ok || i64(pen_x) + i64(x_offset) < i64(min(i32)) || i64(pen_x) + i64(x_offset) > i64(max(i32)) || i64(pen_x) + i64(advance) < i64(min(i32)) || i64(pen_x) + i64(advance) > i64(max(i32)) {
				delete(run.glyphs)
				return errs.new(.Resource_Limit, "DirectWrite glyph position exceeds the layout range", allocator = allocator)
			}
			cluster := glyph_clusters[source_index]
			if cluster < segment.range.start || cluster >= segment.range.end {
				delete(run.glyphs)
				return errs.new(.Internal, "DirectWrite returned an out-of-range source cluster", allocator = allocator)
			}
			if indices[source_index] == 0 {
				diagnose_zero_glyph(result, font.font_id, cluster)
			}
			append(&run.glyphs, Glyph{
				glyph_id = u32(indices[source_index]),
				cluster = cluster,
				x = pen_x + x_offset,
				y = y_offset,
				x_advance = advance,
				y_advance = 0,
				x_offset = x_offset,
				y_offset = y_offset,
			})
			pen_x += advance
		}
		run.advance = pen_x - result.total_advance
		if err := build_clusters(&run, segment, direction, graphemes, allocator); !errs.ok(err) {
			delete(run.glyphs)
			delete(run.clusters)
			return err
		}
		result.total_advance = pen_x
		append(&result.runs, run)
		return {}
	}
	return errs.new(.Resource_Limit, "DirectWrite exceeded the glyph buffer retry budget", allocator = allocator)
}

fixed_26_6 :: proc(value: f32) -> (i32, bool) {
	if math.is_nan(value) || math.is_inf(value) || abs(value) > f32(max(i32)) / 64 {
		return 0, false
	}
	return i32(math.round(value * 64)), true
}

build_clusters :: proc(run: ^Run, segment: Segment, direction: Direction, graphemes: []Byte_Range, allocator := context.allocator) -> errs.Error {
	first_low, first_high := 0, len(graphemes)
	for first_low < first_high {
		middle := first_low + (first_high - first_low) / 2
		if graphemes[middle].end <= segment.range.start {
			first_low = middle + 1
		} else {
			first_high = middle
		}
	}
	first := first_low
	last_low, last_high := first, len(graphemes)
	for last_low < last_high {
		middle := last_low + (last_high - last_low) / 2
		if graphemes[middle].start < segment.range.end {
			last_low = middle + 1
		} else {
			last_high = middle
		}
	}
	last := last_low
	if first == last {
		return errs.new(.Internal, "shaping found no graphemes for a nonempty run", allocator = allocator)
	}
	count := last - first
	run.clusters = make([dynamic]Cluster, count, allocator)
	for visual_index in 0 ..< count {
		logical_index := first + visual_index
		if direction == .RTL {
			logical_index = last - 1 - visual_index
		}
		grapheme := graphemes[logical_index]
		run.clusters[visual_index] = {source_start = grapheme.start, source_end = grapheme.end}
	}

	glyph_index := 0
	minimum_group := 0
	for glyph_index < len(run.glyphs) {
		glyph_cluster := run.glyphs[glyph_index].cluster
		group_advance := i32(0)
		for glyph_index < len(run.glyphs) && run.glyphs[glyph_index].cluster == glyph_cluster {
			group_advance += run.glyphs[glyph_index].x_advance
			glyph_index += 1
		}
		if group_advance < 0 {
			return errs.new(.Internal, "DirectWrite returned a negative horizontal cluster advance", allocator = allocator)
		}
		group_start, found := visual_grapheme_for_cluster(graphemes, first, last, direction, glyph_cluster)
		if !found || group_start < minimum_group {
			return errs.new(.Internal, "DirectWrite cluster is outside or behind its grapheme sequence", allocator = allocator)
		}
		group_end := count - 1
		if glyph_index < len(run.glyphs) {
			next_group, next_found := visual_grapheme_for_cluster(graphemes, first, last, direction, run.glyphs[glyph_index].cluster)
			if !next_found || next_group < group_start {
				return errs.newf(.Internal, "DirectWrite returned non-monotonic grapheme clusters: current=%d next=%d groups=%d,%d direction=%v", glyph_cluster, run.glyphs[glyph_index].cluster, group_start, next_group, direction, allocator = allocator)
			}
			group_end = next_group
			if next_group > group_start {
				group_end = next_group - 1
			}
		}
		group_count := group_end - group_start + 1
		for local_index in 0 ..< group_count {
			start_share := i64(group_advance) * i64(local_index) / i64(group_count)
			end_share := i64(group_advance) * i64(local_index + 1) / i64(group_count)
			run.clusters[group_start + local_index].advance += i32(end_share - start_share)
		}
		minimum_group = group_start
	}

	pen_x := run.glyphs[0].x - run.glyphs[0].x_offset
	for index in 0 ..< count {
		run.clusters[index].x = pen_x
		pen_x += run.clusters[index].advance
	}
	if pen_x != run.glyphs[0].x - run.glyphs[0].x_offset + run.advance {
		return errs.new(.Internal, "DirectWrite grapheme advances do not match the shaped run", allocator = allocator)
	}
	return {}
}

visual_grapheme_for_cluster :: proc(graphemes: []Byte_Range, first, last: int, direction: Direction, cluster: int) -> (int, bool) {
	low, high := first, last
	for low < high {
		middle := low + (high - low) / 2
		grapheme := graphemes[middle]
		if cluster < grapheme.start {
			high = middle
		} else if cluster >= grapheme.end {
			low = middle + 1
		} else {
			if direction == .RTL {
				return last - 1 - middle, true
			}
			return middle - first, true
		}
	}
	return 0, false
}

diagnose_zero_glyph :: proc(result: ^Text, font_id: u64, cluster: int) {
	if len(result.missing) >= MAX_MISSING_DIAGNOSTICS {
		return
	}
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

source_query_interface :: proc "system" (this: ^dw.Text_Analysis_Source, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT {
	if object != nil {
		object^ = nil
	}
	return E_NOINTERFACE
}

sink_query_interface :: proc "system" (this: ^dw.Text_Analysis_Sink, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT {
	if object != nil {
		object^ = nil
	}
	return E_NOINTERFACE
}

analysis_add_ref :: proc "system" (this: rawptr) -> u32 {
	return 1
}

analysis_release :: proc "system" (this: rawptr) -> u32 {
	return 1
}

source_text_at_position :: proc "system" (this: ^dw.Text_Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> windows.HRESULT {
	source := cast(^Analysis_Source_Impl)this
	if text == nil || length == nil || position > u32(len(source.text)) {
		return E_INVALIDARG
	}
	text^ = raw_data(source.text[position:])
	length^ = u32(len(source.text) - int(position))
	return 0
}

source_text_before_position :: proc "system" (this: ^dw.Text_Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> windows.HRESULT {
	source := cast(^Analysis_Source_Impl)this
	if text == nil || length == nil || position > u32(len(source.text)) {
		return E_INVALIDARG
	}
	text^ = raw_data(source.text[:position])
	length^ = position
	return 0
}

source_reading_direction :: proc "system" (this: ^dw.Text_Analysis_Source) -> u32 {
	return 0
}

source_locale_name :: proc "system" (this: ^dw.Text_Analysis_Source, position: u32, length: ^u32, locale: ^cstring16) -> windows.HRESULT {
	if length != nil {
		length^ = 0
	}
	if locale != nil {
		locale^ = nil
	}
	return 0
}

source_number_substitution :: proc "system" (this: ^dw.Text_Analysis_Source, position: u32, length: ^u32, substitution: ^rawptr) -> windows.HRESULT {
	if length != nil {
		length^ = 0
	}
	if substitution != nil {
		substitution^ = nil
	}
	return 0
}

sink_set_script_analysis :: proc "system" (this: ^dw.Text_Analysis_Sink, position: u32, length: u32, analysis: ^dw.Script_Analysis) -> windows.HRESULT {
	sink := cast(^Analysis_Sink_Impl)this
	if analysis == nil || position > sink.text_length || length == 0 || length > sink.text_length - position || sink.count >= len(sink.ranges) {
		sink.failed = true
		return E_INVALIDARG
	}
	sink.ranges[sink.count] = Script_Range{position = position, length = length, analysis = analysis^}
	sink.count += 1
	return 0
}
