#+build linux

package main

import "core:fmt"
import "core:os"
import "core:time"

import errs "hammer:core/errs"
import platform "hammer:platform"
import x11 "hammer:platform/x11clipboard"

MAX_TRANSFER :: 4 * 1024 * 1024
POLL_LIMIT :: 10_000

Client :: struct {
	state:   x11.State,
	service: platform.Clipboard_Service,
}

fail :: proc(message: string) {
	fmt.eprintf("clipboard-driver: %s\n", message)
}

check_error :: proc(err: errs.Error) -> bool {
	if errs.ok(err) {
		return true
	}
	description := errs.describe(err, context.allocator)
	fmt.eprintf("clipboard-driver: %s\n", description)
	delete(description, context.allocator)
	local := err
	errs.destroy(&local)
	return false
}

selection_from_string :: proc(value: string) -> (platform.Clipboard_Selection, bool) {
	switch value {
	case "CLIPBOARD":
		return .Clipboard, true
	case "PRIMARY":
		return .Primary, true
	}
	return {}, false
}

client_init :: proc(client: ^Client) -> bool {
	err := x11.init(&client.state, {
		allow_primary = true,
		max_bytes = MAX_TRANSFER,
		timeout = 5 * time.Second,
		allocator = context.allocator,
	})
	client.service = x11.service()
	return check_error(err)
}

next_result :: proc(client: ^Client) -> (platform.Clipboard_Result, bool) {
	for _ in 0 ..< POLL_LIMIT {
		result, ok := client.service.poll(&client.state, context.allocator)
		if ok {
			return result, true
		}
		time.sleep(time.Millisecond)
	}
	fail("timed out waiting for clipboard result")
	return {}, false
}

write_selection :: proc(client: ^Client, selection: platform.Clipboard_Selection, data: []byte) -> bool {
	err := client.service.start(&client.state, {id = 1, selection = selection, operation = .Write, data = data})
	if !check_error(err) {
		return false
	}
	result, ok := next_result(client)
	if !ok {
		return false
	}
	defer platform.result_destroy(&result)
	if !check_error(result.err) {
		return false
	}
	if result.id != 1 || result.selection != selection || result.operation != .Write || result.ownership != .Owned {
		fail("unexpected clipboard write result")
		return false
	}
	return true
}

run_owner :: proc(selection: platform.Clipboard_Selection, path: string, exit_after_write: bool) -> int {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fail("could not read input file")
		return 1
	}
	defer delete(data)

	client: Client
	if !client_init(&client) {
		return 1
	}
	defer x11.destroy(&client.state)
	if !write_selection(&client, selection, data) {
		return 1
	}
	selection_name := "CLIPBOARD" if selection == .Clipboard else "PRIMARY"
	fmt.printf("ready %s len=%d\n", selection_name, len(data))
	if exit_after_write {
		return 0
	}

	for {
		result, ok := client.service.poll(&client.state, context.allocator)
		if ok {
			lost := result.ownership == .Lost
			platform.result_destroy(&result)
			if lost {
				return 0
			}
		}
		time.sleep(time.Millisecond)
	}
}

run_reader :: proc(selection: platform.Clipboard_Selection, path: string) -> int {
	client: Client
	if !client_init(&client) {
		return 1
	}
	defer x11.destroy(&client.state)

	err := client.service.start(&client.state, {id = 2, selection = selection, operation = .Read})
	if !check_error(err) {
		return 1
	}
	result, ok := next_result(&client)
	if !ok {
		return 1
	}
	defer platform.result_destroy(&result)
	if !check_error(result.err) {
		return 1
	}
	if result.id != 2 || result.selection != selection || result.operation != .Read {
		fail("unexpected clipboard read result")
		return 1
	}
	if write_err := os.write_entire_file(path, result.data); write_err != nil {
		fail("could not write output file")
		return 1
	}
	return 0
}

usage :: proc() {
	fmt.eprintln("usage: clipboard_interop_driver serve|write-exit CLIPBOARD|PRIMARY input-file | read CLIPBOARD|PRIMARY output-file")
}

run :: proc(args: []string) -> int {
	if len(args) == 3 && args[0] == "read" {
		selection, ok := selection_from_string(args[1])
		if !ok {
			usage()
			return 2
		}
		return run_reader(selection, args[2])
	}
	if len(args) == 3 && (args[0] == "serve" || args[0] == "write-exit") {
		selection, ok := selection_from_string(args[1])
		if !ok {
			usage()
			return 2
		}
		return run_owner(selection, args[2], args[0] == "write-exit")
	}
	usage()
	return 2
}

main :: proc() {
	os.exit(run(os.args[1:]))
}
