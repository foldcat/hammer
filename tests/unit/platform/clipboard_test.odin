package platform_test

import "core:testing"

import errs "hammer:core/errs"
import platform "hammer:platform"

expect_clipboard_error :: proc(t: ^testing.T, request: platform.Clipboard_Request, kind: errs.Kind) {
	err := platform.validate_clipboard_request(request, false, 16)
	defer errs.destroy(&err)
	testing.expectf(t, err.kind == kind, "got %v, want %v", err.kind, kind)
}

@(test)
test_clipboard_request_validation :: proc(t: ^testing.T) {
	valid_read := platform.Clipboard_Request{id = 1, operation = .Read}
	read_err := platform.validate_clipboard_request(valid_read, false, 16)
	testing.expect(t, errs.ok(read_err))
	valid_write := platform.Clipboard_Request{id = 2, operation = .Write, data = transmute([]byte)string("a中😀")}
	write_err := platform.validate_clipboard_request(valid_write, false, 16)
	testing.expect(t, errs.ok(write_err))
	primary := valid_read
	primary.selection = .Primary
	primary_err := platform.validate_clipboard_request(primary, true, 16)
	testing.expect(t, errs.ok(primary_err))

	expect_clipboard_error(t, {operation = .Read}, .Invalid_Input)
	expect_clipboard_error(t, primary, .Unsupported)
	expect_clipboard_error(t, {id = 1, operation = .Read, data = {1}}, .Invalid_Input)
	expect_clipboard_error(t, {id = 1, operation = .Write, data = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17}}, .Resource_Limit)
	expect_clipboard_error(t, {id = 1, operation = .Write, data = {0xff}}, .Invalid_Input)
	expect_clipboard_error(t, {id = 1, operation = platform.Clipboard_Operation(99)}, .Invalid_Input)
}

@(test)
test_clipboard_result_ownership :: proc(t: ^testing.T) {
	data := make([]byte, 3)
	copy(data, "abc")
	result := platform.Clipboard_Result {
		id = 9,
		data = data,
		err = errs.new(.IO, "test clipboard error"),
		allocator = context.allocator,
	}
	platform.result_destroy(&result)
	testing.expect(t, result.data == nil && errs.ok(result.err) && result.id == 0)
	platform.result_destroy(&result)
}
