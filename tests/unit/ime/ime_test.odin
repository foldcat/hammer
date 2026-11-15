package ime_test

import "core:testing"

import errs "hammer:core/errs"
import ime "hammer:core/ime"

bytes_of :: proc(text: string) -> []byte {
	return transmute([]byte)text
}

expect_ime_error :: proc(t: ^testing.T, err: errs.Error, kind: errs.Kind) {
	testing.expectf(t, err.kind == kind, "got %v, want %v", err.kind, kind)
	local := err
	errs.destroy(&local)
}

@(test)
test_preedit_unicode_updates_and_done :: proc(t: ^testing.T) {
	state: ime.State
	init_err := ime.init(&state, {})
	defer errs.destroy(&init_err)
	testing.expect(t, errs.ok(init_err))
	defer ime.destroy(&state)

	begin_err := ime.begin(&state)
	defer errs.destroy(&begin_err)
	testing.expect(t, errs.ok(begin_err))
	update_err := ime.update(&state, bytes_of("中a🙂"), 2)
	defer errs.destroy(&update_err)
	testing.expect(t, errs.ok(update_err))
	snapshot := ime.snapshot(&state)
	testing.expect(t, snapshot.active && snapshot.text == "中a🙂" && snapshot.caret == 2)
	caret_err := ime.set_caret(&state, 1)
	defer errs.destroy(&caret_err)
	testing.expect(t, errs.ok(caret_err) && ime.snapshot(&state).caret == 1)

	update_err = ime.update(&state, bytes_of("é"), 1)
	testing.expect(t, errs.ok(update_err))
	snapshot = ime.snapshot(&state)
	testing.expect(t, snapshot.text == "é" && snapshot.caret == 1)
	ime.done(&state)
	snapshot = ime.snapshot(&state)
	testing.expect(t, !snapshot.active && snapshot.text == "" && snapshot.caret == 0)
}

@(test)
test_preedit_invalid_update_preserves_previous_snapshot :: proc(t: ^testing.T) {
	state: ime.State
	testing.expect(t, errs.ok(ime.init(&state, {max_bytes = 8})))
	defer ime.destroy(&state)
	conflict := ime.update(&state, bytes_of("x"), 1)
	expect_ime_error(t, conflict, .Conflict)
	testing.expect(t, errs.ok(ime.begin(&state)))
	testing.expect(t, errs.ok(ime.update(&state, bytes_of("valid"), 3)))

	invalid_utf8 := []byte{0xff}
	invalid := ime.update(&state, invalid_utf8, 0)
	expect_ime_error(t, invalid, .Invalid_Input)
	caret := ime.update(&state, bytes_of("xy"), 3)
	expect_ime_error(t, caret, .Invalid_Input)
	limit := ime.update(&state, bytes_of("123456789"), 1)
	expect_ime_error(t, limit, .Resource_Limit)
	snapshot := ime.snapshot(&state)
	testing.expect(t, snapshot.active && snapshot.text == "valid" && snapshot.caret == 3)

	ime.cancel(&state)
	testing.expect(t, !ime.snapshot(&state).active)
}

@(test)
test_preedit_init_validation_and_reuse :: proc(t: ^testing.T) {
	state: ime.State
	negative := ime.init(&state, {max_bytes = -1})
	expect_ime_error(t, negative, .Invalid_Input)
	testing.expect(t, errs.ok(ime.init(&state, {})))
	defer ime.destroy(&state)
	already := ime.init(&state, {})
	expect_ime_error(t, already, .Conflict)
	testing.expect(t, errs.ok(ime.begin(&state)))
	testing.expect(t, errs.ok(ime.update(&state, nil, 0)))
	snapshot := ime.snapshot(&state)
	testing.expect(t, snapshot.active && snapshot.text == "" && snapshot.caret == 0)
}
