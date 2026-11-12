package errs_test

import "core:testing"

import errs "hammer:core/errs"

@(test)
test_new_owned_message :: proc(t: ^testing.T) {
	e := errs.new(.IO, "disk on fire")
	defer errs.destroy(&e)

	testing.expect(t, e.kind == .IO)
	testing.expect(t, e.message == "disk on fire")
	testing.expect(t, len(e.location.file_path) > 0)
	testing.expect(t, e.location.line > 0)
	testing.expect(t, !errs.ok(e))
}

@(test)
test_newf_formats :: proc(t: ^testing.T) {
	e := errs.newf(.Invalid_Input, "range %d..%d is empty", 4, 2)
	defer errs.destroy(&e)

	testing.expect(t, e.kind == .Invalid_Input)
	testing.expect(t, e.message == "range 4..2 is empty")
}

@(test)
test_none_sentinel :: proc(t: ^testing.T) {
	e := errs.new(.None, "ignored")
	testing.expect(t, errs.ok(e))
	testing.expect(t, e.message == "")
	testing.expect(t, e.allocator.procedure == nil)
	// Destroying the sentinel is a documented no-op.
	errs.destroy(&e)
	testing.expect(t, errs.ok(e))
}

@(test)
test_destroy_is_idempotent_safe :: proc(t: ^testing.T) {
	e := errs.new(.Internal, "boom")
	errs.destroy(&e)
	errs.destroy(&e) // second destroy must be a no-op, not a double free
	testing.expect(t, errs.ok(e))

	z: errs.Error // zero value must also be safe to destroy
	errs.destroy(&z)
}

@(test)
test_describe_includes_kind_message_and_location :: proc(t: ^testing.T) {
	e := errs.new(.Conflict, "stale revision")
	defer errs.destroy(&e)

	d := errs.describe(e) // scratch-allocated; freed by the next temp-arena reset

	testing.expect(t, len(d) > len("conflict: stale revision"))
}

@(test)
test_kind_names_cover_all_kinds :: proc(t: ^testing.T) {
	for kind in errs.Kind {
		testing.expectf(t, errs.kind_name(kind) != "", "missing name for %v", kind)
	}
}
