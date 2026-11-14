// Package filesave implements snapshot-based temporary-write/replace save
// (M03.05, SPECS.md §7.4 and §11.1). It never mutates a document, dirty flag,
// or recorded checkpoint. The caller applies Result only when its revision
// still names the current buffer revision.
package filesave

import "base:runtime"
import "core:fmt"
import "core:os"

import errs "../errs"
import filecodec "../filecodec"
import fileid "../fileid"
import fileload "../fileload"
import rope "../rope"

// Disk_Check is the explicit pre-save external-change policy.
Disk_Check :: enum {
	// The destination must not exist; publication is atomically no-clobber.
	Must_Not_Exist,
	// The destination must still match expected immediately before publication.
	Unchanged,
	// Explicit overwrite: permit external replacement/modification.
	Allow_External_Changes,
}

// Flush_Policy controls durability work before publication. Sync calls fsync /
// FlushFileBuffers on the complete temporary file. Directory-entry durability
// after rename is a separate platform policy and is not claimed here.
Flush_Policy :: enum {
	Sync,
	None,
}

// Options defines the save safety policy. Zero values select Must_Not_Exist,
// follow symlinks, reject read-only files, hard-link breakage, and unverified
// identities, and Sync.
Options :: struct {
	disk_check:               Disk_Check,
	expected:                 fileload.Capture,
	symlinks:                 fileid.Symlink_Policy,
	allow_read_only:          bool,
	allow_hard_link_break:    bool,
	allow_unverified_identity: bool,
	flush:                    Flush_Policy,
	// Optional synchronous OS/fault-injection hooks; borrowed for this call.
	operations:               ^Operation_Hooks,
}

// Snapshot borrows a tree and one immutable root. The tree/store must stay
// alive and unmutated while save_tree reads the root.
Snapshot :: struct {
	tree:     ^rope.Tree,
	root:     ^rope.Node,
	revision: u64,
}

// Result describes a successful publication, or a post-publication error.
// `replaced=true` means the destination already changed even if err is non-nil;
// callers must not blindly retry. A checkpoint is returned only when it was
// captured successfully after publication.
Result :: struct {
	capture:  fileload.Capture,
	revision: u64,
	replaced: bool,
}

Target :: struct {
	path:      string,
	info:      os.File_Info,
	exists:    bool,
	allocator: runtime.Allocator,
}

Existing_Attributes :: struct {
	links:       int,
	permissions: os.Permissions,
}

// save_tree writes a valid internal UTF-8 snapshot according to metadata.
// Newline bytes are preserved exactly; only the metadata-selected UTF-8 BOM is
// added. Non-UTF-8 metadata and invalid BOM combinations are rejected before
// any write. Invalid/unsupported files must first go through filecodec's
// deliberate conversion and enter the editable UTF-8 model.
save_tree :: proc(
	snapshot: Snapshot,
	path: string,
	metadata: filecodec.Metadata,
	options: Options,
	allocator := context.allocator,
) -> (result: Result, err: errs.Error) {
	result.revision = snapshot.revision
	if snapshot.tree == nil || path == "" {
		return result, errs.newf(.Invalid_Input, "filesave: nil tree or empty path", allocator = allocator)
	}
	if metadata.encoding != .UTF8 || (metadata.bom != .None && metadata.bom != .UTF8) {
		return result, errs.newf(
			.Unsupported,
			"filesave: snapshot metadata does not describe UTF-8 with an optional UTF-8 BOM",
			allocator = allocator,
		)
	}

	target, resolve_err := resolve_target(path, options.symlinks, allocator)
	if !errs.ok(resolve_err) {
		return result, resolve_err
	}
	defer target_destroy(&target)
	if options.disk_check == .Must_Not_Exist && target.exists {
		return result, errs.newf(.Conflict, "filesave: %s already exists", path, allocator = allocator)
	}
	if options.disk_check == .Unchanged && !target.exists {
		return result, errs.newf(.Conflict, "filesave: %s no longer exists", path, allocator = allocator)
	}
	if target.exists {
		cap, cap_err := operation_capture(options.operations, target.path, allocator)
		if !errs.ok(cap_err) {
			return result, cap_err
		}
		if options.disk_check == .Unchanged && !checkpoint_acceptable(options, cap.stamp) {
			return result, errs.newf(
				.Conflict,
				"filesave: %s changed since the recorded checkpoint or its identity is unverified",
				path,
				allocator = allocator,
			)
		}
		attrs, attr_err := inspect_attributes(target.path)
		if attr_err != nil {
			return result, errs.newf(.IO, "filesave: cannot inspect %s: %v", target.path, attr_err, allocator = allocator)
		}
		if .Write_User not_in attrs.permissions && !options.allow_read_only {
			return result, errs.newf(.IO, "filesave: %s is read-only", target.path, allocator = allocator)
		}
		if attrs.links > 1 && !options.allow_hard_link_break {
			return result, errs.newf(
				.Unsupported,
				"filesave: %s has %d hard links; atomic replacement would break them (explicitly allow this to proceed)",
				target.path,
				attrs.links,
				allocator = allocator,
			)
		}
	}

	dir := os.dir(target.path)
	if dir == "" {
		dir = "."
	}
	pattern := fmt.aprintf(".%s.tmp-*", os.base(target.path), allocator = allocator)
	defer delete(pattern, allocator)
	temp, temp_err := operation_create_temp(options.operations, dir, pattern)
	if temp_err != nil {
		return result, errs.newf(.IO, "filesave: cannot create a temporary file beside %s: %v", target.path, temp_err, allocator = allocator)
	}
	temp_path := fmt.aprintf("%s", os.name(temp), allocator = allocator)
	defer delete(temp_path, allocator)
	closed := false
	published := false
	defer if !published {
		operation_remove(options.operations, temp_path)
	}
	defer if !closed {
		operation_close(options.operations, temp)
	}

	if metadata.bom == .UTF8 {
		if write_err := write_all(temp, options.operations, transmute([]byte)string("\xef\xbb\xbf")); write_err != nil {
			return result, errs.newf(.IO, "filesave: cannot write UTF-8 BOM to %s: %v", temp_path, write_err, allocator = allocator)
		}
	}
	total := 0 if snapshot.root == nil else snapshot.root.metrics.byte_count
	it: rope.Tree_Span_Iter
	if iter_err := rope.tree_span_iter_init(&it, snapshot.root, {start = 0, end = total}, allocator); !errs.ok(iter_err) {
		return result, iter_err
	}
	for {
		span, more := rope.tree_span_iter_next(&it, snapshot.tree)
		if !more {
			break
		}
		if write_err := write_all(temp, options.operations, span); write_err != nil {
			return result, errs.newf(.IO, "filesave: cannot write snapshot to %s: %v", temp_path, write_err, allocator = allocator)
		}
	}
	if options.flush == .Sync {
		if sync_err := operation_sync(options.operations, temp); sync_err != nil {
			return result, errs.newf(.IO, "filesave: cannot sync %s: %v", temp_path, sync_err, allocator = allocator)
		}
	}
	if target.exists {
		if mode_err := operation_chmod(options.operations, temp, target.info.mode); mode_err != nil {
			return result, errs.newf(.IO, "filesave: cannot preserve permissions on %s: %v", temp_path, mode_err, allocator = allocator)
		}
	}
	if close_err := operation_close(options.operations, temp); close_err != nil {
		closed = true
		return result, errs.newf(.IO, "filesave: cannot close %s: %v", temp_path, close_err, allocator = allocator)
	}
	closed = true

	if options.disk_check != .Allow_External_Changes {
		if check_err := recheck_disk(target.path, options, allocator); !errs.ok(check_err) {
			return result, check_err
		}
	}
	if options.disk_check == .Must_Not_Exist {
		if link_err := operation_link(options.operations, temp_path, target.path); link_err != nil {
			return result, errs.newf(.IO, "filesave: cannot publish new file %s without clobbering: %v", target.path, link_err, allocator = allocator)
		}
		published = true
		result.replaced = true
		if remove_err := operation_remove(options.operations, temp_path); remove_err != nil {
			return result, errs.newf(.IO, "filesave: %s was published but temporary link cleanup failed: %v", target.path, remove_err, allocator = allocator)
		}
	} else {
		if rename_err := operation_rename(options.operations, temp_path, target.path); rename_err != nil {
			return result, errs.newf(.IO, "filesave: cannot replace %s: %v", target.path, rename_err, allocator = allocator)
		}
		published = true
		result.replaced = true
	}

	cap, capture_err := operation_capture(options.operations, target.path, allocator)
	if !errs.ok(capture_err) {
		return result, capture_err
	}
	result.capture = cap
	return result, {}
}

write_all :: proc(file: ^os.File, hooks: ^Operation_Hooks, data: []byte) -> os.Error {
	remaining := data
	for len(remaining) > 0 {
		n, err := operation_write(hooks, file, remaining)
		if err != nil {
			return err
		}
		if n <= 0 {
			return os.General_Error.Invalid_File
		}
		remaining = remaining[n:]
	}
	return nil
}

recheck_disk :: proc(path: string, options: Options, allocator := context.allocator) -> errs.Error {
	if options.disk_check == .Must_Not_Exist {
		info, stat_err := os.lstat(path, allocator)
		if stat_err == .Not_Exist {
			return {}
		}
		if stat_err != nil {
			return errs.newf(.IO, "filesave: cannot recheck %s: %v", path, stat_err, allocator = allocator)
		}
		os.file_info_delete(info, allocator)
		return errs.newf(.Conflict, "filesave: %s appeared before publication", path, allocator = allocator)
	}
	cap, err := operation_capture(options.operations, path, allocator)
	if !errs.ok(err) {
		if err.kind == .NotFound {
			errs.destroy(&err)
			return errs.newf(.Conflict, "filesave: %s disappeared before publication", path, allocator = allocator)
		}
		return err
	}
	if !checkpoint_acceptable(options, cap.stamp) {
		return errs.newf(.Conflict, "filesave: %s changed or its identity is unverified", path, allocator = allocator)
	}
	return {}
}

checkpoint_acceptable :: proc(options: Options, observed: fileid.File_Stamp) -> bool {
	if fileid.stamp_identity_verified(options.expected.stamp, observed) {
		return fileid.stamp_equal(options.expected.stamp, observed)
	}
	return options.allow_unverified_identity && fileid.version_equal(options.expected.stamp, observed)
}

resolve_target :: proc(
	path: string,
	policy: fileid.Symlink_Policy,
	allocator := context.allocator,
) -> (target: Target, err: errs.Error) {
	target.allocator = allocator
	defer if !errs.ok(err) {
		target_destroy(&target)
	}
	target.path, err = absolute_path(path, allocator)
	if !errs.ok(err) {
		return target, err
	}
	for _ in 0 ..< 40 {
		info, stat_err := os.lstat(target.path, allocator)
		if stat_err == .Not_Exist {
			target.exists = false
			return target, {}
		}
		if stat_err != nil {
			err = errs.newf(.IO, "filesave: cannot inspect %s: %v", target.path, stat_err, allocator = allocator)
			return target, err
		}
		if info.type != .Symlink {
			if info.type != .Regular {
				os.file_info_delete(info, allocator)
				err = errs.newf(.Unsupported, "filesave: %s is not a regular file", target.path, allocator = allocator)
				return target, err
			}
			target.info = info
			target.exists = true
			return target, {}
		}
		os.file_info_delete(info, allocator)
		if policy == .Preserve_Link {
			err = errs.newf(.Unsupported, "filesave: refusing to replace symbolic link %s", target.path, allocator = allocator)
			return target, err
		}
		link, link_err := os.read_link(target.path, allocator)
		if link_err != nil {
			err = errs.newf(.IO, "filesave: cannot resolve symbolic link %s: %v", target.path, link_err, allocator = allocator)
			return target, err
		}
		if link == "" {
			delete(link, allocator)
			err = errs.newf(.Unsupported, "filesave: unsupported empty symbolic link target at %s", target.path, allocator = allocator)
			return target, err
		}
		next := link
		if !os.is_absolute_path(link) {
			joined, join_err := os.join_path([]string{os.dir(target.path), link}, allocator)
			delete(link, allocator)
			if join_err != .None {
				err = errs.newf(.Resource_Limit, "filesave: resolving symlink path failed: %v", join_err, allocator = allocator)
				return target, err
			}
			next = joined
		}
		cleaned, clean_err := os.clean_path(next, allocator)
		delete(next, allocator)
		if clean_err != .None {
			err = errs.newf(.Resource_Limit, "filesave: normalizing symlink path failed: %v", clean_err, allocator = allocator)
			return target, err
		}
		delete(target.path, allocator)
		target.path = cleaned
	}
	err = errs.newf(.Invalid_Input, "filesave: too many symbolic links while resolving %s", path, allocator = allocator)
	return target, err
}

absolute_path :: proc(path: string, allocator := context.allocator) -> (string, errs.Error) {
	joined := path
	owned := ""
	if !os.is_absolute_path(path) {
		cwd, cwd_err := os.get_working_directory(allocator)
		if cwd_err != nil {
			return "", errs.newf(.IO, "filesave: cannot determine the working directory: %v", cwd_err, allocator = allocator)
		}
		join_err: runtime.Allocator_Error
		owned, join_err = os.join_path([]string{cwd, path}, allocator)
		delete(cwd, allocator)
		if join_err != .None {
			return "", errs.newf(.Resource_Limit, "filesave: making path absolute failed: %v", join_err, allocator = allocator)
		}
		joined = owned
	}
	cleaned, clean_err := os.clean_path(joined, allocator)
	if owned != "" {
		delete(owned, allocator)
	}
	if clean_err != .None {
		return "", errs.newf(.Resource_Limit, "filesave: normalizing path failed: %v", clean_err, allocator = allocator)
	}
	return cleaned, {}
}

inspect_attributes :: proc(path: string) -> (Existing_Attributes, os.Error) {
	file, err := os.open(path, {.Read})
	if err != nil {
		return {}, err
	}
	defer os.close(file)
	return platform_attributes(file)
}

target_destroy :: proc(target: ^Target) {
	if target.allocator.procedure != nil {
		if target.exists {
			os.file_info_delete(target.info, target.allocator)
		}
		delete(target.path, target.allocator)
	}
	target^ = Target{}
}
