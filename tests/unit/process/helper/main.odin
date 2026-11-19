package main

import "core:fmt"
import "core:os"

report :: proc() -> int {
	for argument in os.args[2:] {
		fmt.printf("arg=%s\n", argument)
	}
	working_dir, dir_err := os.get_working_directory(context.allocator)
	if dir_err != nil {
		fmt.eprintf("cwd error: %v\n", dir_err)
		return 2
	}
	defer delete(working_dir, context.allocator)
	value := os.get_env("HAMMER_PROCESS_TEST", context.allocator)
	defer delete(value, context.allocator)
	path := os.get_env("PATH", context.allocator)
	defer delete(path, context.allocator)
	fmt.printf("cwd=%s\nenv=%s\npath=%s\n", working_dir, value, path)
	fmt.eprintln("stderr=report")
	return 7
}

echo :: proc() -> int {
	input := make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(input)
	buffer: [1024]u8
	for {
		count, err := os.read(os.stdin, buffer[:])
		if count > 0 {
			if len(input) + count > 64 * 1024 {
				return 2
			}
			append(&input, ..buffer[:count])
		}
		if err != nil {
			break
		}
	}
	fmt.printf("stdout=%s\n", string(input[:]))
	fmt.eprintf("stderr=%s\n", string(input[:]))
	return 0
}

flood :: proc() -> int {
	total := 0
	buffer: [4096]u8
	for {
		count, err := os.read(os.stdin, buffer[:])
		total += count
		if total > 1024 * 1024 {
			return 2
		}
		if err != nil {
			break
		}
	}
	for index in 0 ..< 4096 {
		fmt.printf("O%04d:abcdefghijklmnopqrstuvwxyz\n", index)
		fmt.eprintf("E%04d:ABCDEFGHIJKLMNOPQRSTUVWXYZ\n", index)
	}
	fmt.printf("input=%d\n", total)
	return 0
}

wait_for_close :: proc() {
	fmt.println("ready")
	buffer: [1]u8
	os.read(os.stdin, buffer[:])
}

main :: proc() {
	if len(os.args) < 2 {
		os.exit(2)
	}
	code := 0
	switch os.args[1] {
	case "report":
		code = report()
	case "echo":
		code = echo()
	case "flood":
		code = flood()
	case "wait":
		wait_for_close()
	case:
		code = 2
	}
	os.exit(code)
}
