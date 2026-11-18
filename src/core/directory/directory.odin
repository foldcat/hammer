package directory

import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import errs "../errs"

DEFAULT_MAX_ENTRIES :: 4096
DEFAULT_MAX_BYTES :: 1024 * 1024

Options :: struct {
	max_entries: int,
	max_bytes:   int,
}

Entry :: struct {
	name:         string,
	is_directory: bool,
	width:        int,
}

entries_destroy :: proc(entries: ^[dynamic]Entry) {
	for entry in entries {
		delete(entry.name, entries.allocator)
	}
	delete(entries^)
	entries^ = nil
}

read :: proc(path: string, options: Options, allocator := context.allocator) -> (content: []byte, err: errs.Error) {
	if path == "" {
		return nil, errs.new(.Invalid_Input, "directory: empty path", allocator = allocator)
	}
	if options.max_entries < 0 || options.max_bytes < 0 {
		return nil, errs.new(.Invalid_Input, "directory: negative read limit", allocator = allocator)
	}
	max_entries := options.max_entries
	if max_entries == 0 {
		max_entries = DEFAULT_MAX_ENTRIES
	}
	max_bytes := options.max_bytes
	if max_bytes == 0 {
		max_bytes = DEFAULT_MAX_BYTES
	}

	file, open_err := os.open(path, {.Read})
	if open_err != nil {
		kind := errs.Kind.IO
		if open_err == .Not_Exist {
			kind = .NotFound
		}
		return nil, errs.newf(kind, "directory: cannot open %s: %v", path, open_err, allocator = allocator)
	}
	defer os.close(file)
	info, stat_err := os.fstat(file, allocator)
	if stat_err != nil {
		return nil, errs.newf(.IO, "directory: cannot stat %s: %v", path, stat_err, allocator = allocator)
	}
	defer os.file_info_delete(info, allocator)
	if info.type != .Directory {
		return nil, errs.newf(.Unsupported, "directory: %s is not a directory", path, allocator = allocator)
	}

	entries := make([dynamic]Entry, allocator)
	defer entries_destroy(&entries)
	total := 0
	iterator := os.read_directory_iterator_create(file)
	defer os.read_directory_iterator_destroy(&iterator)
	for entry_info in os.read_directory_iterator(&iterator) {
		if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
			return nil, errs.newf(.IO, "directory: cannot read entry %s: %v", error_path, iter_err, allocator = allocator)
		}
		if len(entries) >= max_entries {
			return nil, errs.newf(.Resource_Limit, "directory: %s exceeds the %d-entry limit", path, max_entries, allocator = allocator)
		}
		name := entry_info.name
		if name == "" || !utf8.valid_string(name) {
			return nil, errs.newf(.Unsupported, "directory: %s contains a non-UTF-8 or empty filename", path, allocator = allocator)
		}
		for r in name {
			if r == '\n' || r == '\r' || r < 0x20 || r == 0x7f {
				return nil, errs.newf(.Unsupported, "directory: %s contains a filename with control characters", path, allocator = allocator)
			}
		}
		entry_size := len(name) + 1
		if entry_info.type == .Directory {
			entry_size += 1
		}
		if entry_size > max_bytes - total {
			return nil, errs.newf(.Resource_Limit, "directory: %s exceeds the %d-byte limit", path, max_bytes, allocator = allocator)
		}
		total += entry_size
		owned_name, clone_err := strings.clone(name, allocator)
		if clone_err != .None {
			return nil, errs.newf(.Resource_Limit, "directory: copying a filename failed: %v", clone_err, allocator = allocator)
		}
		_, _, width := utf8.grapheme_count(name)
		if entry_info.type == .Directory {
			width += 1
		}
		_, append_err := append(&entries, Entry{name = owned_name, is_directory = entry_info.type == .Directory, width = width})
		if append_err != .None {
			delete(owned_name, allocator)
			return nil, errs.newf(.Resource_Limit, "directory: growing the entry list failed: %v", append_err, allocator = allocator)
		}
	}
	if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
		return nil, errs.newf(.IO, "directory: cannot finish reading %s near %s: %v", path, error_path, iter_err, allocator = allocator)
	}

	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
		return a.name < b.name
	})
	rows := (len(entries) + 2) / 3
	widths: [3]int
	if rows > 0 {
		for entry, index in entries {
			lane := index / rows
			widths[lane] = max(widths[lane], entry.width)
		}
	}
	total = 0
	for row in 0 ..< rows {
		for lane in 0 ..< 3 {
			index := lane * rows + row
			if index >= len(entries) {
				break
			}
			entry := entries[index]
			total += len(entry.name)
			if entry.is_directory {
				total += 1
			}
			if lane < 2 && index + rows < len(entries) {
				total += widths[lane] - entry.width + 4
			}
		}
		total += 1
	}
	if total > max_bytes {
		return nil, errs.newf(.Resource_Limit, "directory: formatted %s exceeds the %d-byte limit", path, max_bytes, allocator = allocator)
	}
	result := make([dynamic]byte, allocator)
	defer if !errs.ok(err) {
		delete(result)
	}
	if reserve_err := reserve(&result, total); reserve_err != .None {
		return nil, errs.newf(.Resource_Limit, "directory: allocating the listing failed: %v", reserve_err, allocator = allocator)
	}
	for row in 0 ..< rows {
		for lane in 0 ..< 3 {
			index := lane * rows + row
			if index >= len(entries) {
				break
			}
			entry := entries[index]
			append(&result, ..transmute([]byte)entry.name)
			if entry.is_directory {
				append(&result, u8(os.Path_Separator))
			}
			if lane < 2 && index + rows < len(entries) {
				padding := widths[lane] - entry.width + 4
				for _ in 0 ..< padding {
					append(&result, ' ')
				}
			}
		}
		append(&result, '\n')
	}
	return result[:], {}
}
