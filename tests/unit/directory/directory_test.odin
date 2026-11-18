package directory_test

import "core:fmt"
import "core:os"
import "core:testing"

import directory "hammer:core/directory"
import errs "hammer:core/errs"

sandbox :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "hammer-directory-*", context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", err)
	}
	return path
}

expect_ok :: proc(t: ^testing.T, err: $T) {
	when T == errs.Error {
		if !errs.ok(err) {
			description := errs.describe(err, context.allocator)
			testing.expectf(t, false, "unexpected error: %s", description)
			delete(description, context.allocator)
		}
		owned := err
		errs.destroy(&owned)
	} else when T == os.Error {
		testing.expectf(t, err == nil, "unexpected OS error: %v", err)
	} else {
		#panic("unsupported error type")
	}
}

expect_kind :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got %v, expected %v", err.kind, kind)
	owned := err
	errs.destroy(&owned)
}

@(test)
test_sorted_listing_marks_directories_and_preserves_unicode :: proc(t: ^testing.T) {
	root := sandbox(t)
	defer os.remove_all(root)
	expect_ok(t, os.make_directory(fmt.tprintf("%s/sub", root)))
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/zeta.txt", root), "z"))
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/alpha.txt", root), "a"))
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/目标.txt", root), "u"))

	content, err := directory.read(root, {}, context.allocator)
	expect_ok(t, err)
	if !errs.ok(err) {
		return
	}
	defer delete(content, context.allocator)
	testing.expectf(t, string(content) == "alpha.txt    zeta.txt\nsub/         目标.txt\n", "unexpected listing: %q", string(content))
}

@(test)
test_empty_directory_and_regular_file :: proc(t: ^testing.T) {
	root := sandbox(t)
	defer os.remove_all(root)
	content, err := directory.read(root, {}, context.allocator)
	expect_ok(t, err)
	if errs.ok(err) {
		testing.expect(t, len(content) == 0)
		delete(content, context.allocator)
	}
	file := fmt.tprintf("%s/file", root)
	expect_ok(t, os.write_entire_file(file, "contents"))
	content, err = directory.read(file, {}, context.allocator)
	expect_kind(t, err, .Unsupported)
	testing.expect(t, content == nil)
}

@(test)
test_missing_directory_and_invalid_limits :: proc(t: ^testing.T) {
	root := sandbox(t)
	defer os.remove_all(root)
	content, err := directory.read(fmt.tprintf("%s/missing", root), {}, context.allocator)
	expect_kind(t, err, .NotFound)
	testing.expect(t, content == nil)
	content, err = directory.read(root, {max_entries = -1}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	testing.expect(t, content == nil)
	content, err = directory.read("", {}, context.allocator)
	expect_kind(t, err, .Invalid_Input)
	testing.expect(t, content == nil)
}

@(test)
test_entry_and_byte_limits_reject_partial_listings :: proc(t: ^testing.T) {
	root := sandbox(t)
	defer os.remove_all(root)
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/a", root), "a"))
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/bb", root), "b"))
	content, err := directory.read(root, {max_entries = 1}, context.allocator)
	expect_kind(t, err, .Resource_Limit)
	testing.expect(t, content == nil)
	content, err = directory.read(root, {max_bytes = 4}, context.allocator)
	expect_kind(t, err, .Resource_Limit)
	testing.expect(t, content == nil)
	content, err = directory.read(root, {max_entries = 2, max_bytes = 8}, context.allocator)
	expect_ok(t, err)
	if errs.ok(err) {
		testing.expect(t, string(content) == "a    bb\n")
		delete(content, context.allocator)
	}
}

@(test)
test_control_characters_in_names_are_not_ambiguous_listing_lines :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	root := sandbox(t)
	defer os.remove_all(root)
	expect_ok(t, os.write_entire_file(fmt.tprintf("%s/bad\nname", root), "x"))
	content, err := directory.read(root, {}, context.allocator)
	expect_kind(t, err, .Unsupported)
	testing.expect(t, content == nil)
}
