// Positioned text runs. Text owns all run/glyph/grapheme/diagnostic arrays;
// destroy releases them. Glyphs and grapheme layouts use absolute source-byte
// clusters and 26.6 positions.
package shaping

import glyphcache "../glyphcache"

Font :: struct {
	font_id:    u64,
	face_index: int,
	native:     rawptr,
}

Direction :: enum u8 {
	Auto,
	LTR,
	RTL,
}

Options :: struct {
	pixel_size:      u32,
	direction:       Direction,
	ligatures:       bool,
	variation_count: u8,
	variations:      [glyphcache.MAX_VARIATIONS]glyphcache.Variation,
}

Glyph :: struct {
	glyph_id:  u32,
	cluster:   int,
	x, y:      i32,
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
}

// Cluster is one grapheme in visual order. Ligature advances are subdivided
// across their graphemes so every source grapheme boundary remains usable.
Cluster :: struct {
	source_start: int,
	source_end:   int,
	x:            i32,
	advance:      i32,
}

Run :: struct {
	source_start:    int,
	source_end:      int,
	direction:       Direction,
	font_id:         u64,
	face_index:      int,
	pixel_size:      u32,
	variation_count: u8,
	variations:      [glyphcache.MAX_VARIATIONS]glyphcache.Variation,
	glyphs:          [dynamic]Glyph,
	clusters:        [dynamic]Cluster,
	advance:         i32,
}

Missing_Glyph :: struct {
	font_id:       u64,
	codepoint:     rune,
	source_offset: int,
}

Text :: struct {
	runs:          [dynamic]Run,
	missing:       [dynamic]Missing_Glyph,
	total_advance: i32,
}

destroy :: proc(text: ^Text) {
	for run in text.runs {
		delete(run.glyphs)
		delete(run.clusters)
	}
	delete(text.runs)
	delete(text.missing)
	text^ = Text{}
}

cache_key :: proc(run: Run, glyph: Glyph) -> glyphcache.Key {
	return glyphcache.Key{
		font_id = run.font_id,
		face_index = i32(run.face_index),
		glyph_id = glyph.glyph_id,
		pixel_size = run.pixel_size,
		variation_count = run.variation_count,
		variations = run.variations,
	}
}
