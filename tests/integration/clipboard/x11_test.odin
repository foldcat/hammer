#+build linux

package clipboard_test

import "core:bytes"
import "core:testing"
import "core:time"

import errs "hammer:core/errs"
import platform "hammer:platform"
import x11 "hammer:platform/x11clipboard"

XClient :: struct {
	state:   x11.State,
	service: platform.Clipboard_Service,
}

xclient_init :: proc(t: ^testing.T, client: ^XClient, max_bytes := 1024 * 1024, allow_primary := true) {
	err := x11.init(&client.state, {
		allow_primary = allow_primary,
		max_bytes = max_bytes,
		timeout = 2 * time.Second,
		allocator = context.allocator,
	})
	testing.expect(t, errs.ok(err))
	client.service = x11.service()
}

xclient_destroy :: proc(client: ^XClient) {
	x11.destroy(&client.state)
	client.service = {}
}

xstart :: proc(t: ^testing.T, client: ^XClient, request: platform.Clipboard_Request) {
	err := client.service.start(&client.state, request)
	defer errs.destroy(&err)
	testing.expectf(t, errs.ok(err), "%v", errs.describe(err))
}

xnext :: proc(t: ^testing.T, client: ^XClient, owner: ^XClient = nil) -> platform.Clipboard_Result {
	for _ in 0 ..< 5000 {
		if owner != nil {
			other, ok := owner.service.poll(&owner.state, context.allocator)
			if ok {
				platform.result_destroy(&other)
			}
		}
		result, ok := client.service.poll(&client.state, context.allocator)
		if ok {
			return result
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "timed out waiting for X11 clipboard result")
	return {}
}

xwrite :: proc(t: ^testing.T, client: ^XClient, id: platform.Clipboard_Request_ID, selection: platform.Clipboard_Selection, data: []byte) {
	xstart(t, client, {id = id, selection = selection, operation = .Write, data = data})
	result := xnext(t, client)
	defer platform.result_destroy(&result)
	testing.expect(t, result.id == id && result.operation == .Write && result.ownership == .Owned)
	testing.expect(t, errs.ok(result.err))
}

xread :: proc(t: ^testing.T, client: ^XClient, owner: ^XClient, id: platform.Clipboard_Request_ID, selection: platform.Clipboard_Selection) -> platform.Clipboard_Result {
	xstart(t, client, {id = id, selection = selection, operation = .Read})
	return xnext(t, client, owner)
}

@(test)
test_x11_unicode_empty_and_primary_roundtrip :: proc(t: ^testing.T) {
	owner, reader: XClient
	xclient_init(t, &owner)
	defer xclient_destroy(&owner)
	xclient_init(t, &reader)
	defer xclient_destroy(&reader)

	unicode := transmute([]byte)string("ASCII é Ελληνικά кириллица 漢字 A\u0301 😀 עברית")
	xwrite(t, &owner, 1, .Clipboard, unicode)
	result := xread(t, &reader, &owner, 2, .Clipboard)
	testing.expect(t, errs.ok(result.err) && bytes.equal(result.data, unicode))
	platform.result_destroy(&result)

	xwrite(t, &owner, 3, .Clipboard, nil)
	empty := xread(t, &reader, &owner, 4, .Clipboard)
	testing.expect(t, errs.ok(empty.err) && len(empty.data) == 0)
	platform.result_destroy(&empty)

	xwrite(t, &owner, 5, .Primary, unicode)
	primary := xread(t, &reader, &owner, 6, .Primary)
	testing.expect(t, errs.ok(primary.err) && bytes.equal(primary.data, unicode))
	platform.result_destroy(&primary)
}

@(test)
test_x11_large_concurrent_incr_roundtrips :: proc(t: ^testing.T) {
	owner, first, second: XClient
	xclient_init(t, &owner)
	defer xclient_destroy(&owner)
	xclient_init(t, &first)
	defer xclient_destroy(&first)
	xclient_init(t, &second)
	defer xclient_destroy(&second)

	payload := make([]byte, 256 * 1024)
	defer delete(payload)
	for &b in payload {
		b = 'x'
	}
	copy(payload, "中😀")
	xwrite(t, &owner, 10, .Clipboard, payload)
	xstart(t, &first, {id = 11, operation = .Read})
	xstart(t, &second, {id = 12, operation = .Read})

	first_result, second_result: platform.Clipboard_Result
	first_done, second_done := false, false
	for _ in 0 ..< 5000 {
		other, owner_ok := owner.service.poll(&owner.state, context.allocator)
		if owner_ok {
			platform.result_destroy(&other)
		}
		if !first_done {
			result, ok := first.service.poll(&first.state, context.allocator)
			if ok {
				first_result = result
				first_done = true
			}
		}
		if !second_done {
			result, ok := second.service.poll(&second.state, context.allocator)
			if ok {
				second_result = result
				second_done = true
			}
		}
		if first_done && second_done {
			break
		}
		time.sleep(time.Millisecond)
	}
	defer platform.result_destroy(&first_result)
	defer platform.result_destroy(&second_result)
	testing.expect(t, first_done && second_done)
	testing.expect(t, errs.ok(first_result.err) && bytes.equal(first_result.data, payload))
	testing.expect(t, errs.ok(second_result.err) && bytes.equal(second_result.data, payload))
}

@(test)
test_x11_ownership_loss_and_no_owner :: proc(t: ^testing.T) {
	first, second, reader: XClient
	xclient_init(t, &first)
	defer xclient_destroy(&first)
	xclient_init(t, &second)
	defer xclient_destroy(&second)

	text := transmute([]byte)string("first")
	xwrite(t, &first, 20, .Clipboard, text)
	xwrite(t, &second, 21, .Clipboard, transmute([]byte)string("second"))
	lost := xnext(t, &first)
	defer platform.result_destroy(&lost)
	testing.expect(t, lost.id == 20 && lost.ownership == .Lost && errs.ok(lost.err))

	xclient_init(t, &reader)
	defer xclient_destroy(&reader)
	result := xread(t, &reader, &second, 22, .Clipboard)
	testing.expect(t, errs.ok(result.err) && string(result.data) == "second")
	platform.result_destroy(&result)

	x11.destroy(&first.state)
	x11.destroy(&second.state)
	xstart(t, &reader, {id = 23, operation = .Read})
	missing := xnext(t, &reader)
	defer platform.result_destroy(&missing)
	testing.expect(t, missing.err.kind == .NotFound)
}

@(test)
test_x11_cancel_primary_policy_and_budget :: proc(t: ^testing.T) {
	client: XClient
	xclient_init(t, &client, 16, false)
	defer xclient_destroy(&client)

	xstart(t, &client, {id = 30, operation = .Read})
	testing.expect(t, client.service.cancel(&client.state, 30))
	testing.expect(t, !client.service.cancel(&client.state, 30))
	_, ok := client.service.poll(&client.state, context.allocator)
	testing.expect(t, !ok)

	primary_err := client.service.start(&client.state, {id = 31, selection = .Primary, operation = .Read})
	testing.expect(t, primary_err.kind == .Unsupported)
	errs.destroy(&primary_err)
	big := [17]u8{}
	budget_err := client.service.start(&client.state, {id = 32, operation = .Write, data = big[:]})
	testing.expect(t, budget_err.kind == .Resource_Limit)
	errs.destroy(&budget_err)
}
