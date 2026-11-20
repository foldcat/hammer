// Odin source generation: turn a Resolved into the staged generated
// package file (`src/config/generated/generated.odin`). This is the
// SPECS.md §14.1 staging step — the build tool writes the result and
// the Odin compiler turns it into a static package; no runtime
// compilation happens anywhere.
//
// `generate_source` returns a string allocated with `allocator` (the
// caller frees it) containing a complete compilable file.
package config

import "core:fmt"
import "core:os"
import "core:strings"

import errs "../errs"

// GENERATED_HEADER documents provenance inside the generated file and
// tells humans (and diff tools) not to edit it by hand.
GENERATED_HEADER :: "// GENERATED FILE — do not edit by hand."

family_list_literal :: proc(families: []string, allocator := context.allocator) -> string {
	if len(families) == 0 {
		return strings.clone("nil", allocator)
	}
	joined := strings.join(families, "\", \"", allocator)
	defer delete(joined, allocator)
	return strings.concatenate([]string{"[]string {\"", joined, "\"}"}, allocator)
}

// write_staged generates the staged package source for `r` and writes
// it to `path` atomically (temp file + rename): a failed or interrupted
// build can never leave a torn generated file, and an existing file is
// only replaced with a complete one.
write_staged :: proc(r: Resolved, path: string, allocator := context.allocator) -> errs.Error {
	src := generate_source(r, allocator)
	defer delete(src, allocator)

	tmp := strings.concatenate([]string{path, ".tmp"}, allocator)
	defer delete(tmp, allocator)
	if werr := os.write_entire_file(tmp, transmute([]byte)src); werr != nil {
		return errs.newf(.IO, "config: cannot write staged file %s: %v", tmp, werr)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp) // best effort: never leave the temp file behind
		return errs.newf(.IO, "config: cannot replace staged file %s: %v", path, rerr)
	}
	return errs.Error{}
}

// generate_source renders the staged package source for `r`. The result
// is allocated with `allocator`; the caller frees it.
generate_source :: proc(r: Resolved, allocator := context.allocator) -> string {
	source_kind := ".Builtin"
	if r.Source == .File {
		source_kind = ".File"
	}
	wrap_kind := ".Truncate"
	if r.Wrap_Mode == .Soft {
		wrap_kind = ".Soft"
	}

	families_literal := family_list_literal(r.Font_Families, allocator)
	tag_families_literal := family_list_literal(r.Tag_Font_Families, allocator)
	console_families_literal := family_list_literal(r.Console_Font_Families, allocator)
	defer delete(families_literal, allocator)
	defer delete(tag_families_literal, allocator)
	defer delete(console_families_literal, allocator)

	t := r.Theme
	return fmt.aprintf(
		`%s
// Staged by make.odin from %s; regenerated on every build. Config
// edits take effect after rebuilding.

package generated

import config "../../core/config"

#assert(config.SCHEMA_VERSION == %d, "generated config was staged with a different schema version; rebuild via make.odin")

resolved :: config.Resolved {{
    Font_Families         = %s,
    Tag_Font_Families     = %s,
    Console_Font_Families = %s,
    Font_Path             = "%s",
    Font_Size_Points      = %v,
    Line_Height           = %v,
    Ligatures             = %v,
    Autopair              = %v,
    Wrap_Mode             = %s,
    Shell                 = "%s",
    Theme            = config.Theme{{
        Body_Bg      = [4]f32 {{%v, %v, %v, %v}},
        Body_Fg      = [4]f32 {{%v, %v, %v, %v}},
        Tag_Bg       = [4]f32 {{%v, %v, %v, %v}},
        Tag_Fg       = [4]f32 {{%v, %v, %v, %v}},
        Selection_Bg = [4]f32 {{%v, %v, %v, %v}},
        Selection_Fg = [4]f32 {{%v, %v, %v, %v}},
        Caret        = [4]f32 {{%v, %v, %v, %v}},
        Git_Added    = [4]f32 {{%v, %v, %v, %v}},
        Git_Modified = [4]f32 {{%v, %v, %v, %v}},
        Git_Deleted  = [4]f32 {{%v, %v, %v, %v}},
    }},
    Source = %s,
}}
`,
		GENERATED_HEADER,
		source_name(r.Source),
		SCHEMA_VERSION,
		families_literal,
		tag_families_literal,
		console_families_literal,
		r.Font_Path,
		r.Font_Size_Points,
		r.Line_Height,
		r.Ligatures,
		r.Autopair,
		wrap_kind,
		r.Shell,
		t.Body_Bg[0], t.Body_Bg[1], t.Body_Bg[2], t.Body_Bg[3],
		t.Body_Fg[0], t.Body_Fg[1], t.Body_Fg[2], t.Body_Fg[3],
		t.Tag_Bg[0], t.Tag_Bg[1], t.Tag_Bg[2], t.Tag_Bg[3],
		t.Tag_Fg[0], t.Tag_Fg[1], t.Tag_Fg[2], t.Tag_Fg[3],
		t.Selection_Bg[0], t.Selection_Bg[1], t.Selection_Bg[2], t.Selection_Bg[3],
		t.Selection_Fg[0], t.Selection_Fg[1], t.Selection_Fg[2], t.Selection_Fg[3],
		t.Caret[0], t.Caret[1], t.Caret[2], t.Caret[3],
		t.Git_Added[0], t.Git_Added[1], t.Git_Added[2], t.Git_Added[3],
		t.Git_Modified[0], t.Git_Modified[1], t.Git_Modified[2], t.Git_Modified[3],
		t.Git_Deleted[0], t.Git_Deleted[1], t.Git_Deleted[2], t.Git_Deleted[3],
		source_kind,
		allocator = allocator,
	)
}
