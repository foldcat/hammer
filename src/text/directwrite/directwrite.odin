#+build windows

// Narrow DirectWrite bindings used by the Windows font and text adapters.
// COM pointers are owned references unless documented otherwise; release each
// acquired reference exactly once. Analysis callback objects are call-scoped.
package directwrite

import "core:sys/windows"

foreign import dwrite "system:dwrite.lib"

IID_FACTORY := windows.GUID{0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48}}
IID_LOCAL_FONT_FILE_LOADER := windows.GUID{0xb2d9f3ec, 0xc9fe, 0x4a11, {0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2}}

E_NOT_SUFFICIENT_BUFFER :: windows.HRESULT(-2147411846)

succeeded :: proc(result: windows.HRESULT) -> bool {
	return result >= 0
}

Factory_Type :: enum i32 {
	Shared   = 0,
	Isolated = 1,
}

Font_Face_Type :: enum i32 {
	CFF                 = 0,
	TrueType            = 1,
	OpenType_Collection = 2,
	Type1               = 3,
	Vector              = 4,
	Bitmap              = 5,
	Unknown             = 6,
	Raw_CFF             = 7,
}

Font_Simulations :: enum i32 {
	None = 0,
}

Rendering_Mode :: enum i32 {
	Default           = 0,
	Aliased           = 1,
	GDI_Classic       = 2,
	GDI_Natural       = 3,
	Natural           = 4,
	Natural_Symmetric = 5,
	Outline           = 6,
}

Measuring_Mode :: enum i32 {
	Natural     = 0,
	GDI_Classic = 1,
	GDI_Natural = 2,
}

Texture_Type :: enum i32 {
	Aliased_1x1   = 0,
	ClearType_3x1 = 1,
}

Script_Shapes :: enum i32 {
	Default   = 0,
	No_Visual = 1,
}

Font_Feature_Tag :: enum u32 {
	Standard_Ligatures     = 0x6167696c,
	Contextual_Ligatures   = 0x67696c63,
	Discretionary_Ligatures = 0x67696c64,
	Historical_Ligatures   = 0x67696c68,
	Contextual_Alternates  = 0x746c6163,
}

Font_Metrics :: struct {
	design_units_per_em: u16,
	ascent:              u16,
	descent:             u16,
	line_gap:            i16,
	cap_height:          u16,
	x_height:            u16,
	underline_position:  i16,
	underline_thickness: u16,
	strikethrough_position:  i16,
	strikethrough_thickness: u16,
}

Glyph_Metrics :: struct {
	left_side_bearing:   i32,
	advance_width:       u32,
	right_side_bearing:  i32,
	top_side_bearing:    i32,
	advance_height:      u32,
	bottom_side_bearing: i32,
	vertical_origin_y:   i32,
}

Glyph_Offset :: struct {
	advance_offset:  f32,
	ascender_offset: f32,
}

Script_Analysis :: struct {
	script: u16,
	shapes: Script_Shapes,
}

Shaping_Text_Properties :: distinct u16
Shaping_Glyph_Properties :: distinct u16

Font_Feature :: struct {
	name:      Font_Feature_Tag,
	parameter: u32,
}

Typographic_Features :: struct {
	features:      [^]Font_Feature,
	feature_count: u32,
}

Glyph_Run :: struct {
	font_face:        ^Font_Face,
	font_em_size:     f32,
	glyph_count:      u32,
	glyph_indices:    [^]u16,
	glyph_advances:   [^]f32,
	glyph_offsets:    [^]Glyph_Offset,
	is_sideways:      windows.BOOL,
	is_right_to_left: windows.BOOL,
	bidi_level:       u32,
}

IUnknown :: struct {
	vtable: ^IUnknown_VTable,
}

IUnknown_VTable :: struct {
	query_interface: proc "system" (this: ^IUnknown, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:         proc "system" (this: ^IUnknown) -> u32,
	release:         proc "system" (this: ^IUnknown) -> u32,
}

Factory :: struct {
	vtable: ^Factory_VTable,
}

Factory_VTable :: struct {
	query_interface:                 proc "system" (this: ^Factory, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                         proc "system" (this: ^Factory) -> u32,
	release:                         proc "system" (this: ^Factory) -> u32,
	get_system_font_collection:      proc "system" (this: ^Factory, collection: ^^Font_Collection, check_for_updates: windows.BOOL) -> windows.HRESULT,
	create_custom_font_collection:   rawptr,
	register_font_collection_loader: rawptr,
	unregister_font_collection_loader: rawptr,
	create_font_file_reference:      proc "system" (this: ^Factory, path: cstring16, last_write_time: rawptr, file: ^^Font_File) -> windows.HRESULT,
	create_custom_font_file_reference: rawptr,
	create_font_face:                proc "system" (this: ^Factory, face_type: Font_Face_Type, file_count: u32, files: [^]^Font_File, face_index: u32, simulations: Font_Simulations, face: ^^Font_Face) -> windows.HRESULT,
	create_rendering_params:         rawptr,
	create_monitor_rendering_params: rawptr,
	create_custom_rendering_params:  rawptr,
	register_font_file_loader:       rawptr,
	unregister_font_file_loader:     rawptr,
	create_text_format:              rawptr,
	create_typography:               rawptr,
	get_gdi_interop:                 rawptr,
	create_text_layout:              rawptr,
	create_gdi_compatible_text_layout: rawptr,
	create_ellipsis_trimming_sign:   rawptr,
	create_text_analyzer:            proc "system" (this: ^Factory, analyzer: ^^Text_Analyzer) -> windows.HRESULT,
	create_number_substitution:      rawptr,
	create_glyph_run_analysis:       proc "system" (this: ^Factory, run: ^Glyph_Run, pixels_per_dip: f32, transform: rawptr, rendering_mode: Rendering_Mode, measuring_mode: Measuring_Mode, baseline_x, baseline_y: f32, analysis: ^^Glyph_Run_Analysis) -> windows.HRESULT,
}

Font_Collection :: struct {
	vtable: ^Font_Collection_VTable,
}

Font_Collection_VTable :: struct {
	query_interface:       proc "system" (this: ^Font_Collection, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:               proc "system" (this: ^Font_Collection) -> u32,
	release:               proc "system" (this: ^Font_Collection) -> u32,
	get_font_family_count: proc "system" (this: ^Font_Collection) -> u32,
	get_font_family:       proc "system" (this: ^Font_Collection, index: u32, family: ^^Font_Family) -> windows.HRESULT,
	find_family_name:      proc "system" (this: ^Font_Collection, name: cstring16, index: ^u32, exists: ^windows.BOOL) -> windows.HRESULT,
	get_font_from_font_face: rawptr,
}

Font_List :: struct {
	vtable: ^Font_List_VTable,
}

Font_List_VTable :: struct {
	query_interface:     proc "system" (this: ^Font_List, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:             proc "system" (this: ^Font_List) -> u32,
	release:             proc "system" (this: ^Font_List) -> u32,
	get_font_collection: rawptr,
	get_font_count:      proc "system" (this: ^Font_List) -> u32,
	get_font:            proc "system" (this: ^Font_List, index: u32, font: ^^Font) -> windows.HRESULT,
}

Font_Family :: struct {
	vtable: ^Font_Family_VTable,
}

Font_Family_VTable :: struct {
	query_interface:        proc "system" (this: ^Font_Family, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                proc "system" (this: ^Font_Family) -> u32,
	release:                proc "system" (this: ^Font_Family) -> u32,
	get_font_collection:    rawptr,
	get_font_count:         proc "system" (this: ^Font_Family) -> u32,
	get_font:               proc "system" (this: ^Font_Family, index: u32, font: ^^Font) -> windows.HRESULT,
	get_family_names:       proc "system" (this: ^Font_Family, names: ^^Localized_Strings) -> windows.HRESULT,
	get_first_matching_font: proc "system" (this: ^Font_Family, weight: i32, stretch: i32, style: i32, font: ^^Font) -> windows.HRESULT,
	get_matching_fonts:     rawptr,
}

Font :: struct {
	vtable: ^Font_VTable,
}

Font_VTable :: struct {
	query_interface:          proc "system" (this: ^Font, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                  proc "system" (this: ^Font) -> u32,
	release:                  proc "system" (this: ^Font) -> u32,
	get_font_family:          proc "system" (this: ^Font, family: ^^Font_Family) -> windows.HRESULT,
	get_weight:               rawptr,
	get_stretch:              rawptr,
	get_style:                rawptr,
	is_symbol_font:           rawptr,
	get_face_names:           rawptr,
	get_informational_strings: rawptr,
	get_simulations:          rawptr,
	get_metrics:              rawptr,
	has_character:            proc "system" (this: ^Font, codepoint: u32, exists: ^windows.BOOL) -> windows.HRESULT,
	create_font_face:         proc "system" (this: ^Font, face: ^^Font_Face) -> windows.HRESULT,
}

Localized_Strings :: struct {
	vtable: ^Localized_Strings_VTable,
}

Localized_Strings_VTable :: struct {
	query_interface:      proc "system" (this: ^Localized_Strings, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:              proc "system" (this: ^Localized_Strings) -> u32,
	release:              proc "system" (this: ^Localized_Strings) -> u32,
	get_count:            proc "system" (this: ^Localized_Strings) -> u32,
	find_locale_name:     rawptr,
	get_locale_name_length: rawptr,
	get_locale_name:      rawptr,
	get_string_length:    proc "system" (this: ^Localized_Strings, index: u32, length: ^u32) -> windows.HRESULT,
	get_string:           proc "system" (this: ^Localized_Strings, index: u32, buffer: [^]u16, size: u32) -> windows.HRESULT,
}

Font_Face :: struct {
	vtable: ^Font_Face_VTable,
}

Font_Face_VTable :: struct {
	query_interface:                proc "system" (this: ^Font_Face, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                        proc "system" (this: ^Font_Face) -> u32,
	release:                        proc "system" (this: ^Font_Face) -> u32,
	get_type:                       proc "system" (this: ^Font_Face) -> Font_Face_Type,
	get_files:                      proc "system" (this: ^Font_Face, count: ^u32, files: [^]^Font_File) -> windows.HRESULT,
	get_index:                      proc "system" (this: ^Font_Face) -> u32,
	get_simulations:                rawptr,
	is_symbol_font:                 rawptr,
	get_metrics:                    proc "system" (this: ^Font_Face, metrics: ^Font_Metrics),
	get_glyph_count:                proc "system" (this: ^Font_Face) -> u16,
	get_design_glyph_metrics:       proc "system" (this: ^Font_Face, indices: [^]u16, count: u32, metrics: [^]Glyph_Metrics, is_sideways: windows.BOOL) -> windows.HRESULT,
	get_glyph_indices:              proc "system" (this: ^Font_Face, codepoints: [^]u32, count: u32, indices: [^]u16) -> windows.HRESULT,
	try_get_font_table:             rawptr,
	release_font_table:             rawptr,
	get_glyph_run_outline:          rawptr,
	get_recommended_rendering_mode: rawptr,
	get_gdi_compatible_metrics:     rawptr,
	get_gdi_compatible_glyph_metrics: rawptr,
}

Font_File :: struct {
	vtable: ^Font_File_VTable,
}

Font_File_VTable :: struct {
	query_interface:   proc "system" (this: ^Font_File, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:           proc "system" (this: ^Font_File) -> u32,
	release:           proc "system" (this: ^Font_File) -> u32,
	get_reference_key: proc "system" (this: ^Font_File, key: ^rawptr, size: ^u32) -> windows.HRESULT,
	get_loader:        proc "system" (this: ^Font_File, loader: ^^Font_File_Loader) -> windows.HRESULT,
	analyze:           proc "system" (this: ^Font_File, supported: ^windows.BOOL, file_type: ^i32, face_type: ^Font_Face_Type, face_count: ^u32) -> windows.HRESULT,
}

Font_File_Loader :: struct {
	vtable: ^Font_File_Loader_VTable,
}

Font_File_Loader_VTable :: struct {
	query_interface:       proc "system" (this: ^Font_File_Loader, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:               proc "system" (this: ^Font_File_Loader) -> u32,
	release:               proc "system" (this: ^Font_File_Loader) -> u32,
	create_stream_from_key: rawptr,
}

Local_Font_File_Loader :: struct {
	vtable: ^Local_Font_File_Loader_VTable,
}

Local_Font_File_Loader_VTable :: struct {
	query_interface:           proc "system" (this: ^Local_Font_File_Loader, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                   proc "system" (this: ^Local_Font_File_Loader) -> u32,
	release:                   proc "system" (this: ^Local_Font_File_Loader) -> u32,
	create_stream_from_key:    rawptr,
	get_file_path_length_from_key: proc "system" (this: ^Local_Font_File_Loader, key: rawptr, key_size: u32, length: ^u32) -> windows.HRESULT,
	get_file_path_from_key:    proc "system" (this: ^Local_Font_File_Loader, key: rawptr, key_size: u32, path: [^]u16, path_size: u32) -> windows.HRESULT,
	get_last_write_time_from_key: rawptr,
}

Text_Analyzer :: struct {
	vtable: ^Text_Analyzer_VTable,
}

Text_Analyzer_VTable :: struct {
	query_interface:             proc "system" (this: ^Text_Analyzer, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                     proc "system" (this: ^Text_Analyzer) -> u32,
	release:                     proc "system" (this: ^Text_Analyzer) -> u32,
	analyze_script:              proc "system" (this: ^Text_Analyzer, source: ^Text_Analysis_Source, position: u32, length: u32, sink: ^Text_Analysis_Sink) -> windows.HRESULT,
	analyze_bidi:                rawptr,
	analyze_number_substitution: rawptr,
	analyze_line_breakpoints:    rawptr,
	get_glyphs:                  proc "system" (this: ^Text_Analyzer, text: [^]u16, text_length: u32, face: ^Font_Face, is_sideways: windows.BOOL, is_right_to_left: windows.BOOL, script: ^Script_Analysis, locale: cstring16, number_substitution: rawptr, features: [^]^Typographic_Features, feature_range_lengths: [^]u32, feature_ranges: u32, max_glyph_count: u32, cluster_map: [^]u16, text_properties: [^]Shaping_Text_Properties, glyph_indices: [^]u16, glyph_properties: [^]Shaping_Glyph_Properties, actual_glyph_count: ^u32) -> windows.HRESULT,
	get_glyph_placements:        proc "system" (this: ^Text_Analyzer, text: [^]u16, cluster_map: [^]u16, text_properties: [^]Shaping_Text_Properties, text_length: u32, glyph_indices: [^]u16, glyph_properties: [^]Shaping_Glyph_Properties, glyph_count: u32, face: ^Font_Face, em_size: f32, is_sideways: windows.BOOL, is_right_to_left: windows.BOOL, script: ^Script_Analysis, locale: cstring16, features: [^]^Typographic_Features, feature_range_lengths: [^]u32, feature_ranges: u32, advances: [^]f32, offsets: [^]Glyph_Offset) -> windows.HRESULT,
	get_script_properties:       rawptr,
	get_text_complexity:         rawptr,
}

Glyph_Run_Analysis :: struct {
	vtable: ^Glyph_Run_Analysis_VTable,
}

Glyph_Run_Analysis_VTable :: struct {
	query_interface:         proc "system" (this: ^Glyph_Run_Analysis, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                 proc "system" (this: ^Glyph_Run_Analysis) -> u32,
	release:                 proc "system" (this: ^Glyph_Run_Analysis) -> u32,
	get_alpha_texture_bounds: proc "system" (this: ^Glyph_Run_Analysis, texture_type: Texture_Type, bounds: ^windows.RECT) -> windows.HRESULT,
	create_alpha_texture:    proc "system" (this: ^Glyph_Run_Analysis, texture_type: Texture_Type, bounds: ^windows.RECT, alpha: [^]u8, buffer_size: u32) -> windows.HRESULT,
	get_alpha_blend_params:  rawptr,
}

Text_Analysis_Source :: struct {
	vtable: ^Text_Analysis_Source_VTable,
}

Text_Analysis_Source_VTable :: struct {
	query_interface:                proc "system" (this: ^Text_Analysis_Source, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                        proc "system" (this: rawptr) -> u32,
	release:                        proc "system" (this: rawptr) -> u32,
	get_text_at_position:           proc "system" (this: ^Text_Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> windows.HRESULT,
	get_text_before_position:       proc "system" (this: ^Text_Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> windows.HRESULT,
	get_paragraph_reading_direction: proc "system" (this: ^Text_Analysis_Source) -> u32,
	get_locale_name:                proc "system" (this: ^Text_Analysis_Source, position: u32, length: ^u32, locale: ^cstring16) -> windows.HRESULT,
	get_number_substitution:        proc "system" (this: ^Text_Analysis_Source, position: u32, length: ^u32, substitution: ^rawptr) -> windows.HRESULT,
}

Text_Analysis_Sink :: struct {
	vtable: ^Text_Analysis_Sink_VTable,
}

Text_Analysis_Sink_VTable :: struct {
	query_interface:          proc "system" (this: ^Text_Analysis_Sink, iid: ^windows.GUID, object: ^rawptr) -> windows.HRESULT,
	add_ref:                  proc "system" (this: rawptr) -> u32,
	release:                  proc "system" (this: rawptr) -> u32,
	set_script_analysis:      proc "system" (this: ^Text_Analysis_Sink, position: u32, length: u32, analysis: ^Script_Analysis) -> windows.HRESULT,
	set_line_breakpoints:     rawptr,
	set_bidi_level:           rawptr,
	set_number_substitution:  rawptr,
}

Native_Face :: struct {
	face:     ^Font_Face,
	factory:  ^Factory,
	analyzer: ^Text_Analyzer,
}

release :: proc(object: rawptr) {
	if object == nil {
		return
	}
	unknown := cast(^IUnknown)object
	unknown.vtable.release(unknown)
}

query_interface :: proc(object: rawptr, iid: ^windows.GUID, result: ^rawptr) -> windows.HRESULT {
	if object == nil || result == nil {
		return windows.HRESULT(-2147024809)
	}
	result^ = nil
	unknown := cast(^IUnknown)object
	return unknown.vtable.query_interface(unknown, iid, result)
}

@(default_calling_convention = "c")
foreign dwrite {
	DWriteCreateFactory :: proc(factory_type: Factory_Type, iid: ^windows.GUID, factory: ^rawptr) -> windows.HRESULT ---
}

create_factory :: proc() -> (^Factory, windows.HRESULT) {
	result: rawptr
	status := DWriteCreateFactory(.Shared, &IID_FACTORY, &result)
	if !succeeded(status) || result == nil {
		return nil, status
	}
	return cast(^Factory)result, 0
}

#assert(size_of(Font_Metrics) == 20)
#assert(size_of(Glyph_Metrics) == 28)
#assert(size_of(Glyph_Offset) == 8)
#assert(size_of(Script_Analysis) == 8)
#assert(size_of(Glyph_Run) == 56)
