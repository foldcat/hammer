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

	families_literal := "nil"
	families_owned := false
	if len(r.Font_Families) > 0 {
		// Family names are validated to be plain strings without quotes
		// or backslashes (see `validate`), so a ".." Odin literal is a
		// faithful representation.
		joined := strings.join(r.Font_Families, "\", \"", allocator)
		families_literal = strings.concatenate([]string{"[]string {\"", joined, "\"}"}, allocator)
		delete(joined, allocator)
		families_owned = true
	}
	// Proc-scope defer (Odin defers are block-scoped): the literal must
	// stay alive until aprintf below has copied it.
	defer if families_owned {
		delete(families_literal, allocator)
	}

	t := r.Theme
	return fmt.aprintf(
		`%s
// Staged by make.odin from %s; regenerated on every build. Config
// edits take effect after rebuilding.

package generated

import config "../../core/config"

#assert(config.SCHEMA_VERSION == %d, "generated config was staged with a different schema version; rebuild via make.odin")

resolved :: config.Resolved {{
    Font_Families    = %s,
    Font_Size_Points = %v,
    Line_Height      = %v,
    Ligatures        = %v,
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
		r.Font_Size_Points,
		r.Line_Height,
		r.Ligatures,
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
