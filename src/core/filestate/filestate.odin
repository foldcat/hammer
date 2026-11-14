// Package filestate classifies on-disk changes against a load/save checkpoint
// (M03.06, SPECS.md §11.2). It polls synchronously and returns plain values;
// callers retain sole ownership of buffer roots, dirty state, and reload/apply
// decisions. No observation silently changes editor state.
package filestate

import errs "../errs"
import fileid "../fileid"
import fileload "../fileload"

// Change describes the destination relative to its recorded checkpoint.
Change :: enum {
	Unchanged,
	Modified,
	Replaced,
	Missing,
}

// Action is the safe next choice offered to the buffer owner.
Action :: enum {
	None,
	Offer_Reload,
	Resolve_Conflict,
}

// Conflict_Action enumerates deliberate choices for a dirty-buffer conflict.
Conflict_Action :: enum {
	Reload_Discard_Local,
	Keep_Local,
	Save_As,
	Compare,
	Explicit_Overwrite,
}

Conflict_Actions :: distinct bit_set[Conflict_Action]

DIRTY_CONFLICT_ACTIONS :: Conflict_Actions {
	.Reload_Discard_Local,
	.Keep_Local,
	.Save_As,
	.Compare,
	.Explicit_Overwrite,
}

MISSING_CONFLICT_ACTIONS :: Conflict_Actions {
	.Keep_Local,
	.Save_As,
}

// Observation is a plain, non-owning result. `identity_verified=false` warns
// that identity-less filesystems cannot distinguish same-metadata replacement.
// `actions` is nonempty exactly when action is Resolve_Conflict.
Observation :: struct {
	change:            Change,
	action:            Action,
	actions:           Conflict_Actions,
	identity_verified: bool,
	observed:          fileload.Capture,
}

// observe_file captures path through a read-only handle and classifies it.
// A missing file is an ordinary `.Missing` observation, not an I/O error.
// Other capture failures are returned and never misreported as unchanged.
observe_file :: proc(
	path: string,
	expected: fileload.Capture,
	dirty: bool,
	allocator := context.allocator,
) -> (Observation, errs.Error) {
	if path == "" {
		return {}, errs.newf(.Invalid_Input, "filestate: empty path", allocator = allocator)
	}
	observed, err := fileload.capture_file(path, allocator)
	if !errs.ok(err) {
		if err.kind == .NotFound {
			errs.destroy(&err)
			return classify_missing(dirty), {}
		}
		return {}, err
	}
	return classify(expected, observed, dirty), {}
}

// classify compares two valid captures without performing I/O.
classify :: proc(expected, observed: fileload.Capture, dirty: bool) -> Observation {
	observation := Observation {
		identity_verified = fileid.stamp_identity_verified(expected.stamp, observed.stamp),
		observed = observed,
	}
	switch fileid.stamp_status(expected.stamp, observed.stamp) {
	case .Unchanged:
		observation.change = .Unchanged
	case .Changed:
		observation.change = .Modified
	case .Replaced:
		observation.change = .Replaced
	}
	if observation.change != .Unchanged {
		if dirty {
			observation.action = .Resolve_Conflict
			observation.actions = DIRTY_CONFLICT_ACTIONS
		} else {
			observation.action = .Offer_Reload
		}
	}
	return observation
}

// classify_missing models deletion or a dangling destination. A clean buffer
// is not offered a reload into nonexistent content; a dirty buffer requires an
// explicit conflict decision and cannot use in-place explicit overwrite.
classify_missing :: proc(dirty: bool) -> Observation {
	observation := Observation{change = .Missing}
	if dirty {
		observation.action = .Resolve_Conflict
		observation.actions = MISSING_CONFLICT_ACTIONS
	}
	return observation
}
