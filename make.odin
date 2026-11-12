package main

import "core:fmt"
import "core:os"
import "core:strings"

SRC_DIR :: "./src"
OUT_DIR :: "./build"
BINARY_NAME :: "hammer"
BINARY_PATH :: OUT_DIR + "/" + BINARY_NAME

SOKOL_COLLECTION :: "-collection:sokol=./third_party/sokol"

main :: proc() {
	args := os.args
	mode := "debug"

	if len(args) > 1 {
		cmd := args[1]
		switch cmd {
		case "run":
			mode = "run"
		case "build":
			mode = "build"
		case:
			for arg in args {
				if strings.contains(arg, "--release") {
					mode = "release"
					break
				}
			}
		}
	}

	for arg in args {
		if strings.contains(arg, "--release") {
			mode = "release"
			break
		}
	}

	cmd_args: []string
	switch mode {
	case "run":
		fmt.println("[Build] Running project (Debug)...")
		cmd_args = []string{"odin", "run", SRC_DIR, SOKOL_COLLECTION, "-vet", "-debug"}
	case "build":
		fmt.println("[Build] Building project (Debug) -> " + BINARY_PATH + "...")
		cmd_args = []string {
			"odin",
			"build",
			SRC_DIR,
			SOKOL_COLLECTION,
			"-vet",
			"-out:" + BINARY_PATH,
			"-debug",
		}
	case "release":
		fmt.println(
			"[Build] Building project (Release with optimizations) -> " + BINARY_PATH + "...",
		)
		cmd_args = []string {
			"odin",
			"build",
			SRC_DIR,
			SOKOL_COLLECTION,
			"-vet",
			"-out:" + BINARY_PATH,
			"-o:speed",
			"-no-bounds-check",
		}
	case:
		fmt.println("[Build] Building project (Debug default) -> " + BINARY_PATH + "...")
		cmd_args = []string {
			"odin",
			"build",
			SRC_DIR,
			SOKOL_COLLECTION,
			"-vet",
			"-out:" + BINARY_PATH,
			"-debug",
		}
	}

	desc := os.Process_Desc {
		command = cmd_args,
	}

	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
	defer delete(stdout)
	defer delete(stderr)

	if err != nil {
		fmt.eprintf("[Build] Failed to execute process: %v\n", err)
		os.exit(1)
	}

	if len(stdout) > 0 {
		fmt.print(string(stdout))
	}
	if len(stderr) > 0 {
		fmt.eprint(string(stderr))
	}

	if state.exit_code != 0 {
		fmt.eprintf("[Build] Command exited with code %d\n", state.exit_code)
		os.exit(int(state.exit_code))
	}
}
