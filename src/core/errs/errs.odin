// Package errs: structured recoverable errors for the editor core.
//
// Ownership contract (AGENTS.md §11.1):
//
// - An `Error` is a plain value: a `Kind` plus an owned, heap-allocated
//   message plus the source location where it was created.
// - `new`/`newf` allocate the message with the caller-provided
//   allocator. From that point the message is **owned by the Error
//   value** and must be released with `destroy` exactly once.
// - An `Error` with `kind == .None` is the "no error" sentinel: its
//   message is empty and it must not be destroyed. Use `ok` to test.
// - Assigning an `Error` to another variable transfers ownership by
//   copy; never destroy both copies.
package errs

import "base:runtime"
import "core:fmt"
import "core:strings"

// Kind classifies a recoverable error so callers can react without
// parsing messages (AGENTS.md §11.1).
Kind :: enum {
	None, // no error; zero-value sentinel
	Invalid_Input, // bad external input (ranges, addresses, config values)
	Unsupported, // valid request, feature not available here
	IO, // file / platform I/O failure
	Conflict, // revision or external-modification conflict
	Cancelled, // asynchronous work was cancelled
	Resource_Limit, // a budget (queue, size, count) was exceeded
	Internal, // invariant violation that is not fatal; log and carry
}

Error :: struct {
	kind: Kind,
	// message is owned by the Error once set; see `destroy`.
	message: string,
	// allocator used for `message`; kept so `destroy` is self-contained.
	// Only meaningful while `message` is non-empty.
	allocator: runtime.Allocator,
	location:  runtime.Source_Code_Location,
}

// new returns an Error of the given kind whose message is an owned copy
// of `message` (allocated with `allocator`). A kind of .None returns the
// no-error sentinel and does not copy the message.
new :: proc(
	kind: Kind,
	message: string,
	location := #caller_location,
	allocator := context.allocator,
) -> Error {
	if kind == .None {
		return Error{kind = .None, location = location}
	}
	return Error{
		kind = kind,
		message = strings.clone(message, allocator),
		allocator = allocator,
		location = location,
	}
}

// newf is `new` with printf-style formatting of the message.
newf :: proc(
	kind: Kind,
	format: string,
	args: ..any,
	location := #caller_location,
	allocator := context.allocator,
) -> Error {
	if kind == .None {
		return Error{kind = .None, location = location}
	}
	return Error{
		kind = kind,
		message = fmt.aprintf(format, ..args, allocator = allocator),
		allocator = allocator,
		location = location,
	}
}

// ok reports whether `e` is the no-error sentinel.
ok :: proc(e: Error) -> bool {
	return e.kind == .None
}

// destroy releases the message owned by `e` and resets it to the
// no-error sentinel. Destroying the sentinel (or a zero Error) is safe
// and does nothing.
destroy :: proc(e: ^Error) {
	if e.allocator.procedure != nil && e.message != "" {
		delete(e.message, e.allocator)
	}
	e^ = Error{}
}

// kind_name returns a short human-readable name for `kind`.
kind_name :: proc(kind: Kind) -> string {
	#partial switch kind {
	case .None:
		return "no error"
	case .Invalid_Input:
		return "invalid input"
	case .Unsupported:
		return "unsupported"
	case .IO:
		return "I/O failure"
	case .Conflict:
		return "conflict"
	case .Cancelled:
		return "cancelled"
	case .Resource_Limit:
		return "resource limit"
	case .Internal:
		return "internal error"
	}
	return "unknown error kind"
}

// describe renders `e` as "<kind>: <message> (<file>:<line>:<proc>)".
// The result is allocated with `allocator` (default: scratch); callers
// needing a longer lifetime must pass a persistent allocator.
describe :: proc(e: Error, allocator := context.temp_allocator) -> string {
	if e.kind == .None {
		return "no error"
	}
	loc := e.location
	return fmt.aprintf(
		"%s: %s (%s:%d:%s)",
		kind_name(e.kind),
		e.message,
		loc.file_path,
		loc.line,
		loc.procedure,
		allocator = allocator,
	)
}
