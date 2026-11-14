package filesave_test

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:testing"

import chunk "hammer:core/chunk"
import errs "hammer:core/errs"
import filecodec "hammer:core/filecodec"
import fileid "hammer:core/fileid"
import fileload "hammer:core/fileload"
import filesave "hammer:core/filesave"
import rope "hammer:core/rope"

Tree_Fixture :: struct {
	store: chunk.Store,
	tree:  rope.Tree,
}

fixture_init :: proc(t: ^testing.T, fixture: ^Tree_Fixture, content: string) {
	chunk.init(&fixture.store, {chunk_size = 3}, context.allocator)
	if err := rope.tree_init(&fixture.tree, &fixture.store, {target_leaf_bytes = 8}, context.allocator); !expect_ok(t, err) {
		return
	}
	if err := rope.tree_append(&fixture.tree, transmute([]byte)content, context.allocator); !expect_ok(t, err) {
		return
	}
}

fixture_destroy :: proc(fixture: ^Tree_Fixture) {
	rope.tree_destroy(&fixture.tree)
	chunk.destroy(&fixture.store)
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
	if err.kind != kind {
		desc := errs.describe(err, context.allocator)
		testing.expectf(t, false, "got %v, want %v: %s", err.kind, kind, desc)
		delete(desc, context.allocator)
	}
	owned_err := err
	errs.destroy(&owned_err)
}

sandbox :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "hammer-filesave-*", context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "cannot create sandbox: %v", err)
		return ""
	}
	return dir
}

write_fixture :: proc(t: ^testing.T, path, content: string) {
	if err := os.write_entire_file(path, transmute([]byte)content); err != nil {
		testing.expectf(t, false, "cannot write %s: %v", path, err)
	}
}

read_fixture :: proc(t: ^testing.T, path: string) -> []byte {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		testing.expectf(t, false, "cannot read %s: %v", path, err)
		return nil
	}
	return data
}

load_fixture :: proc(t: ^testing.T, loaded: ^fileload.Loaded, path: string) -> bool {
	return expect_ok(t, fileload.load_file(loaded, path, {chunk_size = 2}, context.allocator))
}

expect_only_one_entry :: proc(t: ^testing.T, path: string, expected := 1) {
	dir, err := os.open(path)
	if err != nil {
		testing.expectf(t, false, "cannot open directory %s: %v", path, err)
		return
	}
	defer os.close(dir)
	entries, read_err := os.read_all_directory(dir, context.allocator)
	if read_err != nil {
		testing.expectf(t, false, "cannot read directory %s: %v", path, read_err)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expectf(t, len(entries) == expected, "unexpected directory contents in %s: %d entries, want %d", path, len(entries), expected)
}

utf8_metadata :: proc(bom: filecodec.BOM = .None) -> filecodec.Metadata {
	return filecodec.Metadata{encoding = .UTF8, bom = bom}
}

@(test)
test_save_new_snapshot_bom_newlines_and_reopen :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/new.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "before\r\nβ\n")
	defer fixture_destroy(&fixture)
	root := fixture.tree.root
	if !expect_ok(t, rope.tree_append(&fixture.tree, transmute([]byte)string(" later"), context.allocator)) {return}

	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = root, revision = 41},
		path,
		utf8_metadata(.UTF8),
		{},
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	testing.expect(t, result.replaced)
	testing.expect(t, result.revision == 41)
	testing.expect(t, result.capture.stamp.size == u64(len("before\r\nβ\n") + 3))
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, bytes.equal(data, transmute([]byte)string("\xef\xbb\xbfbefore\r\nβ\n")))
	expect_only_one_entry(t, dir)

	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	defer fileload.loaded_destroy(&loaded)
	decoded := filecodec.decode_loaded(&loaded)
	testing.expect(t, decoded.status == .Valid_UTF8)
	testing.expect(t, decoded.metadata.bom == .UTF8)
	testing.expect(t, decoded.metadata.newline == .Mixed)
	testing.expect(t, decoded.content.length == len("before\r\nβ\n"))
	testing.expect(t, fileid.stamp_equal(result.capture.stamp, loaded.capture.stamp))
}

@(test)
test_save_existing_preserves_permissions_and_refreshes_checkpoint :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/existing.txt", dir)
	write_fixture(t, path, "old")
	if err := os.chmod(path, os.perm_number(0o640)); err != nil {
		testing.expectf(t, false, "chmod failed: %v", err)
		return
	}
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new\r\ncontent")
	defer fixture_destroy(&fixture)
	options := filesave.Options{disk_check = .Unchanged, expected = expected}
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root, revision = 7},
		path,
		utf8_metadata(),
		options,
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "new\r\ncontent")
	info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		testing.expectf(t, false, "stat failed: %v", stat_err)
		return
	}
	defer os.file_info_delete(info, context.allocator)
	testing.expectf(t, info.mode == os.perm_number(0o640), "mode changed to %v", info.mode)

	result2, err2 := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root, revision = 8},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = result.capture},
		context.allocator,
	)
	if !expect_ok(t, err2) {return}
	testing.expect(t, result2.capture.stamp.size == result.capture.stamp.size)
	expect_only_one_entry(t, dir)
}

@(test)
test_save_stale_checkpoint_conflicts_without_touching_disk :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/conflict.txt", dir)
	write_fixture(t, path, "old")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	write_fixture(t, path, "external-longer")
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "local")
	defer fixture_destroy(&fixture)

	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected},
		context.allocator,
	)
	expect_kind(t, err, .Conflict)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "external-longer")
	expect_only_one_entry(t, dir)
}

@(test)
test_save_explicit_overwrite_replaces_external_change :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/overwrite.txt", dir)
	write_fixture(t, path, "old")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	write_fixture(t, path, "external")
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "local")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Allow_External_Changes, expected = expected},
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	testing.expect(t, result.replaced)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "local")
}

@(test)
test_save_as_never_clobbers_existing_path :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/existing.txt", dir)
	write_fixture(t, path, "keep")
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "replace")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{},
		context.allocator,
	)
	expect_kind(t, err, .Conflict)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "keep")
	expect_only_one_entry(t, dir)
}

@(test)
test_save_follows_symlink_without_replacing_link :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	target := fmt.tprintf("%s/target.txt", dir)
	link := fmt.tprintf("%s/link.txt", dir)
	write_fixture(t, target, "old")
	if err := os.symlink("target.txt", link); err != nil {
		testing.expectf(t, false, "symlink failed: %v", err)
		return
	}
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, link) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		link,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected},
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	testing.expect(t, result.replaced)
	data := read_fixture(t, target)
	defer delete(data)
	testing.expect(t, string(data) == "new")
	info, stat_err := os.lstat(link, context.allocator)
	if stat_err != nil {
		testing.expectf(t, false, "lstat failed: %v", stat_err)
		return
	}
	defer os.file_info_delete(info, context.allocator)
	testing.expect(t, info.type == .Symlink)
}

@(test)
test_save_preserve_link_policy_rejects_symlink :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	target := fmt.tprintf("%s/target.txt", dir)
	link := fmt.tprintf("%s/link.txt", dir)
	write_fixture(t, target, "old")
	if err := os.symlink("target.txt", link); err != nil {
		testing.expectf(t, false, "symlink failed: %v", err)
		return
	}
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		link,
		utf8_metadata(),
		{disk_check = .Allow_External_Changes, symlinks = .Preserve_Link},
		context.allocator,
	)
	expect_kind(t, err, .Unsupported)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, target)
	defer delete(data)
	testing.expect(t, string(data) == "old")
}

@(test)
test_save_symlink_cycle_is_bounded :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	a := fmt.tprintf("%s/a", dir)
	b := fmt.tprintf("%s/b", dir)
	if err := os.symlink("b", a); err != nil {
		testing.expectf(t, false, "symlink failed: %v", err)
		return
	}
	if err := os.symlink("a", b); err != nil {
		testing.expectf(t, false, "symlink failed: %v", err)
		return
	}
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		a,
		utf8_metadata(),
		{},
		context.allocator,
	)
	expect_kind(t, err, .Invalid_Input)
	testing.expect(t, !result.replaced)
}

@(test)
test_save_read_only_policy_and_permission_preservation :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/readonly.txt", dir)
	write_fixture(t, path, "old")
	if err := os.chmod(path, os.perm_number(0o444)); err != nil {
		testing.expectf(t, false, "chmod failed: %v", err)
		return
	}
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected},
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, path)
	testing.expect(t, string(data) == "old")
	delete(data)

	allowed, allow_err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected, allow_read_only = true},
		context.allocator,
	)
	if !expect_ok(t, allow_err) {return}
	testing.expect(t, allowed.replaced)
	data = read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "new")
	info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		testing.expectf(t, false, "stat failed: %v", stat_err)
		return
	}
	defer os.file_info_delete(info, context.allocator)
	testing.expect(t, info.mode == os.perm_number(0o444))
}

@(test)
test_save_hard_link_policy_is_explicit :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/original.txt", dir)
	other := fmt.tprintf("%s/other.txt", dir)
	write_fixture(t, path, "old")
	if err := os.link(path, other); err != nil {
		testing.expectf(t, false, "hard link failed: %v", err)
		return
	}
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected},
		context.allocator,
	)
	expect_kind(t, err, .Unsupported)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, other)
	testing.expect(t, string(data) == "old")
	delete(data)

	allowed, allow_err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected, allow_hard_link_break = true},
		context.allocator,
	)
	if !expect_ok(t, allow_err) {return}
	testing.expect(t, allowed.replaced)
	data = read_fixture(t, path)
	testing.expect(t, string(data) == "new")
	delete(data)
	other_data := read_fixture(t, other)
	defer delete(other_data)
	testing.expect(t, string(other_data) == "old")
}

@(test)
test_save_rejects_non_utf8_policy_before_creating_file :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/unsupported.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "text")
	defer fixture_destroy(&fixture)
	metadata := filecodec.Metadata{encoding = .UTF16_LE, bom = .UTF16_LE}
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		metadata,
		{disk_check = .Allow_External_Changes},
		context.allocator,
	)
	expect_kind(t, err, .Unsupported)
	testing.expect(t, !result.replaced)
	testing.expect(t, !os.exists(path))
	expect_only_one_entry(t, dir, 0)
}

@(test)
test_save_missing_parent_fails_without_publication :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/missing/file.txt", dir)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "text")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{},
		context.allocator,
	)
	expect_kind(t, err, .IO)
	testing.expect(t, !result.replaced)
	testing.expect(t, !os.exists(path))
	expect_only_one_entry(t, dir, 0)
}

@(test)
test_save_empty_snapshot_replaces_with_empty_file :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/empty.txt", dir)
	write_fixture(t, path, "not empty")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = nil, revision = 99},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected, flush = .None},
		context.allocator,
	)
	if !expect_ok(t, err) {return}
	testing.expect(t, result.replaced && result.revision == 99)
	testing.expect(t, result.capture.stamp.size == 0)
	data := read_fixture(t, path)
	defer delete(data)
	testing.expect(t, len(data) == 0)
	expect_only_one_entry(t, dir)
}

@(test)
test_save_unverified_identity_requires_explicit_permission :: proc(t: ^testing.T) {
	dir := sandbox(t)
	if dir == "" {return}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/unverified.txt", dir)
	write_fixture(t, path, "old")
	loaded: fileload.Loaded
	if !load_fixture(t, &loaded, path) {return}
	expected := loaded.capture
	fileload.loaded_destroy(&loaded)
	expected.id = fileid.FILE_ID_NONE
	expected.stamp.id = fileid.FILE_ID_NONE
	fixture: Tree_Fixture
	fixture_init(t, &fixture, "new")
	defer fixture_destroy(&fixture)
	result, err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected},
		context.allocator,
	)
	expect_kind(t, err, .Conflict)
	testing.expect(t, !result.replaced)
	data := read_fixture(t, path)
	testing.expect(t, string(data) == "old")
	delete(data)

	allowed, allow_err := filesave.save_tree(
		{tree = &fixture.tree, root = fixture.tree.root},
		path,
		utf8_metadata(),
		{disk_check = .Unchanged, expected = expected, allow_unverified_identity = true},
		context.allocator,
	)
	if !expect_ok(t, allow_err) {return}
	testing.expect(t, allowed.replaced)
	data = read_fixture(t, path)
	defer delete(data)
	testing.expect(t, string(data) == "new")
}
