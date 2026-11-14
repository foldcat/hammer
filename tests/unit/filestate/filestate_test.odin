package filestate_test

import "core:fmt"
import "core:os"
import "core:testing"

import errs "hammer:core/errs"
import fileid "hammer:core/fileid"
import fileload "hammer:core/fileload"
import filestate "hammer:core/filestate"

capture_model :: proc(id: fileid.File_ID, size: u64, mtime: i64) -> fileload.Capture {
	return fileload.Capture {
		id = id,
		stamp = fileid.File_Stamp{id = id, size = size, mtime_sec = mtime},
	}
}

expect_ok :: proc(t: ^testing.T, err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	desc := errs.describe(err, context.allocator)
	testing.expectf(t, false, "unexpected error: %s", desc)
	delete(desc, context.allocator)
	owned_err := err
	errs.destroy(&owned_err)
	return false
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expect(t, err.kind == kind)
	owned_err := err
	errs.destroy(&owned_err)
}

sandbox :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "hammer-filestate-*", context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", err)
	}
	return dir
}

@(test)
test_unchanged_never_offers_reload_or_conflict :: proc(t: ^testing.T) {
	id := fileid.unix_id(10, 20)
	expected := capture_model(id, 10, 100)
	dirty_values := [2]bool{false, true}
	for dirty in dirty_values {
		observation := filestate.classify(expected, expected, dirty)
		testing.expect(t, observation.change == .Unchanged)
		testing.expect(t, observation.action == .None)
		testing.expect(t, observation.actions == filestate.Conflict_Actions{})
		testing.expect(t, observation.identity_verified)
		testing.expect(t, fileid.stamp_identity_verified(expected.stamp, observation.observed.stamp))
	}
}

@(test)
test_clean_change_offers_reload_and_dirty_change_exposes_all_choices :: proc(t: ^testing.T) {
	expected := capture_model(fileid.unix_id(10, 20), 10, 100)
	observed_cases := []fileload.Capture {
		capture_model(fileid.unix_id(10, 20), 11, 100),
		capture_model(fileid.unix_id(10, 21), 10, 100),
	}
	for observed in observed_cases {
		clean := filestate.classify(expected, observed, false)
		testing.expect(t, clean.action == .Offer_Reload)
		testing.expect(t, clean.actions == filestate.Conflict_Actions{})
		dirty := filestate.classify(expected, observed, true)
		testing.expect(t, dirty.action == .Resolve_Conflict)
		testing.expect(t, dirty.actions == filestate.DIRTY_CONFLICT_ACTIONS)
		testing.expect(t, .Reload_Discard_Local in dirty.actions)
		testing.expect(t, .Keep_Local in dirty.actions)
		testing.expect(t, .Save_As in dirty.actions)
		testing.expect(t, .Compare in dirty.actions)
		testing.expect(t, .Explicit_Overwrite in dirty.actions)
		testing.expect(t, dirty.identity_verified)
	}
}

@(test)
test_missing_clean_is_not_reloadable_and_dirty_has_safe_choices :: proc(t: ^testing.T) {
	clean := filestate.classify_missing(false)
	testing.expect(t, clean.change == .Missing)
	testing.expect(t, clean.action == .None)
	testing.expect(t, clean.actions == filestate.Conflict_Actions{})
	dirty := filestate.classify_missing(true)
	testing.expect(t, dirty.change == .Missing)
	testing.expect(t, dirty.action == .Resolve_Conflict)
	testing.expect(t, dirty.actions == filestate.MISSING_CONFLICT_ACTIONS)
	testing.expect(t, .Keep_Local in dirty.actions)
	testing.expect(t, .Save_As in dirty.actions)
	testing.expect(t, .Explicit_Overwrite not_in dirty.actions)
	testing.expect(t, .Reload_Discard_Local not_in dirty.actions)
}

@(test)
test_identity_less_unchanged_is_explicitly_unverified :: proc(t: ^testing.T) {
	none := capture_model(fileid.FILE_ID_NONE, 10, 100)
	observation := filestate.classify(none, none, true)
	testing.expect(t, observation.change == .Unchanged)
	testing.expect(t, observation.action == .None)
	testing.expect(t, !observation.identity_verified)
	testing.expect(t, !fileid.stamp_identity_verified(none.stamp, none.stamp))

	changed := capture_model(fileid.FILE_ID_NONE, 11, 100)
	conflict := filestate.classify(none, changed, true)
	testing.expect(t, conflict.change == .Modified)
	testing.expect(t, conflict.action == .Resolve_Conflict)
	testing.expect(t, !conflict.identity_verified)
}

@(test)
test_real_file_modification_replacement_and_missing :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/file.txt", dir)
	if err := os.write_entire_file(path, transmute([]byte)string("old")); err != nil {
		testing.expectf(t, false, "write failed: %v", err)
		return
	}
	loaded: fileload.Loaded
	if !expect_ok(t, fileload.load_file(&loaded, path, {chunk_size = 1}, context.allocator)) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)

	unchanged, err := filestate.observe_file(path, expected, false, context.allocator)
	if !expect_ok(t, err) {return}
	testing.expect(t, unchanged.change == .Unchanged && unchanged.action == .None)
	testing.expect(t, unchanged.identity_verified)

	if write_err := os.write_entire_file(path, transmute([]byte)string("external-longer")); write_err != nil {
		testing.expectf(t, false, "write failed: %v", write_err)
		return
	}
	modified, modified_err := filestate.observe_file(path, expected, false, context.allocator)
	if !expect_ok(t, modified_err) {return}
	testing.expect(t, modified.change == .Modified && modified.action == .Offer_Reload)
	dirty, dirty_err := filestate.observe_file(path, expected, true, context.allocator)
	if !expect_ok(t, dirty_err) {return}
	testing.expect(t, dirty.change == .Modified && dirty.action == .Resolve_Conflict)

	replacement := fmt.tprintf("%s/replacement.txt", dir)
	if write_err := os.write_entire_file(replacement, transmute([]byte)string("external-longer")); write_err != nil {
		testing.expectf(t, false, "write failed: %v", write_err)
		return
	}
	if rename_err := os.rename(replacement, path); rename_err != nil {
		testing.expectf(t, false, "rename failed: %v", rename_err)
		return
	}
	replaced, replaced_err := filestate.observe_file(path, expected, true, context.allocator)
	if !expect_ok(t, replaced_err) {return}
	testing.expect(t, replaced.change == .Replaced)
	testing.expect(t, replaced.action == .Resolve_Conflict)

	if remove_err := os.remove(path); remove_err != nil {
		testing.expectf(t, false, "remove failed: %v", remove_err)
		return
	}
	missing, missing_err := filestate.observe_file(path, expected, true, context.allocator)
	if !expect_ok(t, missing_err) {return}
	testing.expect(t, missing.change == .Missing)
	testing.expect(t, missing.action == .Resolve_Conflict)
	testing.expect(t, missing.actions == filestate.MISSING_CONFLICT_ACTIONS)
}

@(test)
test_observation_errors_are_not_reported_as_changes :: proc(t: ^testing.T) {
	_, err := filestate.observe_file("", {}, false, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	_, dir_err := filestate.observe_file(dir, {}, false, context.allocator)
	expect_kind(t, dir_err, .Unsupported)
}
