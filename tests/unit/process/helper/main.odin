package main

import "core:fmt"
import "core:os"
import "core:time"

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

context_report :: proc() -> int {
	working_dir, dir_err := os.get_working_directory(context.allocator)
	if dir_err != nil {
		return 2
	}
	defer delete(working_dir, context.allocator)
	fmt.printf("cwd=%s\n", working_dir)
	variables := []string{
		"ACME_WINDOW_ID",
		"ACME_BUFFER_ID",
		"ACME_FILE",
		"ACME_ADDRESS",
		"ACME_PROJECT_ROOT",
		"ACME_INSTANCE_ROOT",
		"ACME_ENDPOINT",
		"CUSTOM",
		"PATH",
	}
	for key in variables {
		value := os.get_env(key, context.allocator)
		defer delete(value, context.allocator)
		fmt.printf("%s=%s\n", key, value)
	}
	return 0
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

pipe_delay :: proc() -> int {
	time.sleep(time.Second)
	return pipe()
}

pipe :: proc() -> int {
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
	fmt.printf("filtered:%s", string(input[:]))
	fmt.eprintln("pipe diagnostic")
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

ignore_until_killed :: proc() {
	ignore_termination()
	fmt.println("ready")
	for {
		time.sleep(10 * time.Millisecond)
	}
}

// mark writes a fixed marker file in the current working directory and emits a
// small amount of output, giving a discard-routing invocation an observable
// side effect that does not depend on an output window.
mark :: proc() -> int {
	write_err := os.write_entire_file("discard-marker.txt", "ran\n")
	if write_err != nil {
		fmt.eprintf("mark write error: %v\n", write_err)
		return 2
	}
	fmt.println("discard stdout")
	fmt.eprintln("discard stderr")
	return 0
}

wait_for_close :: proc() {
	fmt.println("ready")
	buffer: [1]u8
	os.read(os.stdin, buffer[:])
}

// pty reports whether stdin is a TTY, then echoes one input line. Used to
// verify that a PTY child sees a terminal and that master I/O round-trips.
pty :: proc() -> int {
	tty_flag := 0
	if os.is_tty(os.stdin) {
		tty_flag = 1
	}
	fmt.printf("tty=%d\n", tty_flag)
	input := make([dynamic]u8, 0, 256, context.allocator)
	defer delete(input)
	buffer: [1]u8
	for len(input) < 256 {
		count, err := os.read(os.stdin, buffer[:])
		if count > 0 {
			append(&input, ..buffer[:count])
			if buffer[0] == '\n' {
				break
			}
		}
		if err != nil {
			break
		}
	}
	fmt.printf("echo:%s", string(input[:]))
	return 0
}

// size reports the terminal window size the child observes via TIOCGWINSZ.
// (Defined per-platform: see size_linux.odin / size_other.odin.)

// ansi emits ANSI-styled text, a CR progress update, and a trailing partial
// line, so the output decoder can be verified end to end (M10.06).
ansi :: proc() -> int {
	fmt.printf("\x1b[31mred\x1b[0m\n\x1b[32mgreen\x1b[0m\n")
	fmt.printf("abcde\rvwxyz\n")
	fmt.printf("no-newline-tail")
	return 0
}

main :: proc() {
	if len(os.args) < 2 {
		os.exit(2)
	}
	code := 0
	switch os.args[1] {
	case "context":
		code = context_report()
	case "report":
		code = report()
	case "echo":
		code = echo()
	case "pipe":
		code = pipe()
	case "pipe-delay":
		code = pipe_delay()
	case "flood":
		code = flood()
	case "ignore":
		ignore_until_killed()
	case "mark":
		code = mark()
	case "wait":
		wait_for_close()
	case "pty":
		code = pty()
	case "size":
		code = size()
	case "ansi":
		code = ansi()
	case "envcheck":
		code = envcheck()
	case:
		code = 2
	}
	os.exit(code)
}
