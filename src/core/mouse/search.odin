package mouse

import errs "../errs"
import rope "../rope"
import txn "../txn"

MAX_SEARCH_DOCUMENT_BYTES :: 64 * 1024 * 1024

find_literal :: proc(
	doc: ^txn.Doc,
	needle: []byte,
	start: int,
	reverse: bool,
	allocator := context.allocator,
) -> (rope.Byte_Range, bool, errs.Error) {
	if doc == nil {
		return {}, false, errs.new(.Invalid_Input, "mouse: nil search document", allocator = allocator)
	}
	total := rope.tree_byte_count(&doc.tree)
	if start < 0 || start > total {
		return {}, false, errs.new(.Invalid_Input, "mouse: search origin is outside the document", allocator = allocator)
	}
	if total > MAX_SEARCH_DOCUMENT_BYTES {
		return {}, false, errs.newf(.Resource_Limit, "mouse: search document exceeds the %d-byte budget", MAX_SEARCH_DOCUMENT_BYTES, allocator = allocator)
	}
	if len(needle) == 0 || len(needle) > total {
		return {}, false, {}
	}
	if len(needle) > MAX_ACTION_TEXT_BYTES {
		return {}, false, errs.newf(.Resource_Limit, "mouse: search text exceeds the %d-byte budget", MAX_ACTION_TEXT_BYTES, allocator = allocator)
	}
	failure, alloc_err := make([]int, len(needle), allocator)
	if alloc_err != .None {
		return {}, false, errs.newf(.Resource_Limit, "mouse: allocating search state failed: %v", alloc_err, allocator = allocator)
	}
	defer delete(failure, allocator)
	for index, matched := 1, 0; index < len(needle); index += 1 {
		for matched > 0 && needle[index] != needle[matched] {
			matched = failure[matched - 1]
		}
		if needle[index] == needle[matched] {
			matched += 1
		}
		failure[index] = matched
	}

	first := -1
	first_after := -1
	last := -1
	last_before := -1
	matched := 0
	position := 0
	iter: rope.Tree_Span_Iter
	if err := rope.tree_span_iter_init(&iter, doc.tree.root, {0, total}, allocator); !errs.ok(err) {
		return {}, false, err
	}
	for {
		span, more := rope.tree_span_iter_next(&iter, &doc.tree)
		if !more {
			break
		}
		for b in span {
			for matched > 0 && b != needle[matched] {
				matched = failure[matched - 1]
			}
			if b == needle[matched] {
				matched += 1
			}
			position += 1
			if matched == len(needle) {
				found := position - len(needle)
				if first < 0 {
					first = found
				}
				if first_after < 0 && found >= start {
					first_after = found
				}
				last = found
				if found + len(needle) <= start {
					last_before = found
				}
				matched = failure[matched - 1]
			}
		}
	}
	found := first_after
	if reverse {
		found = last_before
		if found < 0 {
			found = last
		}
	} else if found < 0 {
		found = first
	}
	if found < 0 {
		return {}, false, {}
	}
	return {found, found + len(needle)}, true, {}
}
