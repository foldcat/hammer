// Hammer build tool. Paths are resolved relative to this file, so it can
// be run from anywhere:
//
//     odin run make.odin -file                 # debug build
//     odin run make.odin -file -- run          # debug build + run
//     odin run make.odin -file -- --release    # optimized build
//     odin run make.odin -file -- clipboard-spike  # M00.04 X11 spike
//     odin run make.odin -file -- dpi-ime-spike    # M00.05 DPI/IME spike
//     odin run make.odin -file -- wayland-spike    # M00.06 Wayland spike
//     odin run make.odin -file -- pty-spike        # M00.07 PTY spike
//     odin run make.odin -file -- fuse-spike       # M00.08 FUSE spike
//
// On Linux this tool also self-configures the Sokol dependency: it
// downloads the pinned Sokol C sources (verified by sha256), checks the
// system build dependencies, and compiles the Sokol static libraries the
// Odin bindings link against. All generated artifacts live in build/ or
// are covered by the repository .gitignore rules.
package main

import "core:fmt"
import "core:os"
import "core:strings"

SRC_DIR :: #directory + "/src"
OUT_DIR :: #directory + "/build"
BINARY_NAME :: "hammer"
BINARY_PATH :: OUT_DIR + "/" + BINARY_NAME

// M00.04 clipboard spike: a standalone X11 (Xlib) program with no Sokol
// dependency, built by the `clipboard-spike` target.
SPIKE_CLIPBOARD_DIR :: #directory + "/spike/clipboard"
CLIPBOARD_SPIKE_PATH :: OUT_DIR + "/clipboard_spike"

SPIKE_DIR :: #directory + "/spike"
SPIKE_COLLECTION :: "-collection:spike=" + SPIKE_DIR

// M00.05 DPI/IME spike: a native X11 probe plus a sapp probe app, built
// by the `dpi-ime-spike` target.
SPIKE_DPI_IME_DIR :: SPIKE_DIR + "/dpi_ime"
SPIKE_DPI_IME_APP_DIR :: SPIKE_DPI_IME_DIR + "/app"
DPI_IME_PATH :: OUT_DIR + "/dpi_ime"
DPI_IME_APP_PATH :: OUT_DIR + "/dpi_ime_app"

// M00.06 Wayland spike: a GLFW-based native Wayland window (vendor:glfw
// linking the system libglfw3; needs a compositor at runtime).
SPIKE_WAYLAND_DIR :: SPIKE_DIR + "/wayland"
WAYLAND_SPIKE_PATH :: OUT_DIR + "/wayland_spike"

// M00.07 PTY spike: parent spike plus the helper child it spawns on the
// slave side of the pty.
SPIKE_PTY_DIR :: SPIKE_DIR + "/pty"
SPIKE_PTY_CHILD_DIR :: SPIKE_PTY_DIR + "/child"
PTY_SPIKE_PATH :: OUT_DIR + "/pty_spike"
PTY_CHILD_PATH :: OUT_DIR + "/pty_child"

// M00.08 FUSE spike: a minimal raw-protocol FUSE filesystem daemon (no
// libfuse), built by the `fuse-spike` target. Mounts via mount(2) when
// privileged or the setuid fusermount3 helper otherwise.
SPIKE_FUSE_DIR :: SPIKE_DIR + "/fuse"
FUSE_SPIKE_PATH :: OUT_DIR + "/fuse_spike"

SOKOL_PKG_DIR :: #directory + "/third_party/sokol/sokol"
SOKOL_COLLECTION :: "-collection:sokol=" + SOKOL_PKG_DIR

// Pinned Sokol C sources (floooh/sokol), the revision tracked by the
// pinned sokol-odin bindings (third_party/sokol, commit ae94aa5).
SOKOL_C_COMMIT :: "93aa187b5d387cc24b7290b3ca3f13f61e139e7c"
SOKOL_C_URL :: "https://codeload.github.com/floooh/sokol/tar.gz/" + SOKOL_C_COMMIT
SOKOL_C_SHA256 :: "3e5a1b365cd221a8bd386a472cc9450eb7a0a6e93ce9a7fe6f86f8eb07a785c9"
SOKOL_C_DIR :: #directory + "/third_party/sokol-c"
SOKOL_GEN_DIR :: OUT_DIR + "/sokol"

SOKOL_HEADERS := []string {
	"sokol_app.h",
	"sokol_gfx.h",
	"sokol_glue.h",
	"sokol_log.h",
	"sokol_time.h",
}

SOKOL_VARIANTS := []string{"debug", "release"}

Sokol_Lib :: struct {
	name:         string, // "sokol_app"
	pkg:          string, // binding package directory under third_party/sokol/sokol/
	impl_define:  string, // impl guard define for this library
	pre_includes: []string, // headers included before the library header, in order
}

SOKOL_LIBS := []Sokol_Lib {
	{"sokol_app", "app", "SOKOL_APP_IMPL", nil},
	{"sokol_gfx", "gfx", "SOKOL_GFX_IMPL", nil},
	{"sokol_glue", "glue", "SOKOL_GLUE_IMPL", []string{"sokol_app.h", "sokol_gfx.h"}},
	{"sokol_log", "log", "SOKOL_LOG_IMPL", nil},
}

main :: proc() {
	args := os.args

	// M00.04 clipboard spike: standalone X11 program, no Sokol needed.
	if len(args) > 1 && args[1] == "clipboard-spike" {
		fmt.println("[Build] Building clipboard spike -> " + CLIPBOARD_SPIKE_PATH + "...")
		run_odin([]string {
			"odin",
			"build",
			SPIKE_CLIPBOARD_DIR,
			"-vet",
			"-out:" + CLIPBOARD_SPIKE_PATH,
		})
		return
	}

	// M00.05 DPI/IME spike: native X11 probe + sapp probe app.
	if len(args) > 1 && args[1] == "dpi-ime-spike" {
		fmt.println("[Build] Building DPI/IME spike...")
		run_odin([]string {
			"odin",
			"build",
			SPIKE_DPI_IME_DIR,
			SPIKE_COLLECTION,
			"-vet",
			"-out:" + DPI_IME_PATH,
		})
		run_odin([]string {
			"odin",
			"build",
			SPIKE_DPI_IME_APP_DIR,
			SOKOL_COLLECTION,
			SPIKE_COLLECTION,
			"-vet",
			"-out:" + DPI_IME_APP_PATH,
		})
		return
	}

	// M00.06 Wayland spike: GLFW-based native Wayland window.
	if len(args) > 1 && args[1] == "wayland-spike" {
		fmt.println("[Build] Building Wayland spike -> " + WAYLAND_SPIKE_PATH + "...")
		run_odin([]string {
			"odin",
			"build",
			SPIKE_WAYLAND_DIR,
			"-vet",
			"-out:" + WAYLAND_SPIKE_PATH,
		})
		return
	}

	// M00.07 PTY spike: parent spike plus the child helper it spawns.
	if len(args) > 1 && args[1] == "pty-spike" {
		fmt.println("[Build] Building PTY spike -> " + PTY_SPIKE_PATH + "...")
		run_odin([]string {
			"odin",
			"build",
			SPIKE_PTY_DIR,
			"-vet",
			"-out:" + PTY_SPIKE_PATH,
		})
		run_odin([]string {
			"odin",
			"build",
			SPIKE_PTY_CHILD_DIR,
			"-vet",
			"-out:" + PTY_CHILD_PATH,
		})
		return
	}

	// M00.08 FUSE spike: standalone raw-protocol FUSE daemon, core only.
	if len(args) > 1 && args[1] == "fuse-spike" {
		fmt.println("[Build] Building FUSE spike -> " + FUSE_SPIKE_PATH + "...")
		run_odin([]string {
			"odin",
			"build",
			SPIKE_FUSE_DIR,
			"-vet",
			"-out:" + FUSE_SPIKE_PATH,
		})
		return
	}

	when ODIN_OS == .Linux {
		if !setup_sokol_linux() {
			fmt.eprintln("[Build] Sokol setup failed; cannot continue.")
			os.exit(1)
		}
	} else {
		fmt.println(
			"[Build] note: automatic Sokol setup is only implemented on Linux (X11) for now.",
		)
	}

	mode := "debug"
	if len(args) > 1 {
		switch args[1] {
		case "run":
			mode = "run"
		case "build":
			mode = "build"
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
		fmt.println("[Build] Building project (Release) -> " + BINARY_PATH + "...")
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

	run_odin(cmd_args)
}

// run_odin executes an Odin invocation, forwards its output, and exits
// nonzero if the command fails.
run_odin :: proc(cmd_args: []string) {
	desc := os.Process_Desc{command = cmd_args}
	// Owned heap buffers: deleted after use.
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
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

// --- Sokol setup (Linux only) -----------------------------------------

setup_sokol_linux :: proc() -> bool {
	if !sokol_headers_present() {
		fmt.println("[Setup] Sokol C headers not found; downloading the pinned revision...")
		if !fetch_sokol_headers() {
			return false
		}
	}
	if !system_deps_present() {
		return false
	}
	return build_sokol_libs()
}

sokol_headers_present :: proc() -> bool {
	for header in SOKOL_HEADERS {
		if !os.exists(fmt.tprintf("%s/%s", SOKOL_C_DIR, header)) {
			return false
		}
	}
	return true
}

fetch_sokol_headers :: proc() -> bool {
	os.make_directory_all(OUT_DIR)
	os.make_directory_all(SOKOL_C_DIR)
	os.make_directory_all(SOKOL_GEN_DIR)

	tarball := OUT_DIR + "/sokol-c.tar.gz"
	extract_dir := OUT_DIR + "/sokol-" + SOKOL_C_COMMIT

	fmt.printf("[Setup] Downloading %s\n", SOKOL_C_URL)
	if !run_tool([]string{"curl", "-fsSL", "-o", tarball, SOKOL_C_URL}) {
		fmt.eprintln("[Setup] download failed")
		return false
	}

	fmt.println("[Setup] Verifying sha256...")
	if !sha256_ok(tarball, SOKOL_C_SHA256) {
		fmt.eprintln("[Setup] checksum mismatch; refusing to use the downloaded archive")
		return false
	}

	fmt.println("[Setup] Extracting...")
	if !run_tool([]string{"tar", "-xzf", tarball, "-C", OUT_DIR}) {
		fmt.eprintln("[Setup] extraction failed")
		return false
	}

	for header in SOKOL_HEADERS {
		src := fmt.tprintf("%s/%s", extract_dir, header)
		dst := fmt.tprintf("%s/%s", SOKOL_C_DIR, header)
		data, err := os.read_entire_file(src, context.temp_allocator)
		if err != nil {
			fmt.eprintf("[Setup] cannot read %s: %v\n", src, err)
			return false
		}
		if werr := os.write_entire_file(dst, data); werr != nil {
			fmt.eprintf("[Setup] cannot write %s: %v\n", dst, werr)
			return false
		}
	}

	// Record the exact revision for auditability.
	commit: string = SOKOL_C_COMMIT
	if werr := os.write_entire_file(SOKOL_C_DIR + "/SOURCE_COMMIT", transmute([]byte)commit); werr != nil {
		fmt.eprintf("[Setup] cannot write %s/SOURCE_COMMIT: %v\n", SOKOL_C_DIR, werr)
		return false
	}

	// build/ is a generated-output directory; clean up our temp artifacts.
	os.remove(tarball)
	os.remove_all(extract_dir)

	fmt.printf("[Setup] Sokol C headers installed in %s\n", SOKOL_C_DIR)
	return true
}

sha256_ok :: proc(path, expected: string) -> bool {
	desc := os.Process_Desc{command = []string{"sha256sum", path}}
	// temp-allocated output; borrowed for the duration of this proc only.
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		fmt.eprintln("[Setup] cannot compute sha256")
		return false
	}
	line := string(stdout)
	if len(line) < len(expected) {
		return false
	}
	return line[:len(expected)] == expected
}

system_deps_present :: proc() -> bool {
	missing: [dynamic]string
	defer delete(missing)

	if !run_tool([]string{"cc", "--version"}, true) {
		append(&missing, "C compiler (cc)")
	}
	if !run_tool([]string{"ar", "--version"}, true) {
		append(&missing, "ar (binutils)")
	}

	// The Sokol libraries link against X11, Xi, Xcursor and GL at final
	// link time; the dev symlinks must be present.
	libs := []string{"libX11.so", "libXi.so", "libXcursor.so", "libGL.so"}
	cache := ""
	desc := os.Process_Desc{command = []string{"ldconfig", "-p"}}
	// temp-allocated output; borrowed for the duration of this proc only.
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if err == nil && state.exit_code == 0 {
		cache = string(stdout)
	}
	for lib in libs {
		if !strings.contains(cache, lib) {
			append(&missing, lib)
		}
	}

	if len(missing) == 0 {
		return true
	}
	fmt.eprintln("[Setup] missing build dependencies:")
	for item in missing {
		fmt.eprintf("[Setup]   - %s\n", item)
	}
	fmt.eprintln(
		"[Setup] Gentoo: emerge -av x11-libs/libX11 x11-libs/libXi x11-libs/libXcursor media-libs/mesa sys-devel/binutils",
	)
	fmt.eprintln(
		"[Setup] Debian/Ubuntu: apt install libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev build-essential",
	)
	return false
}

build_sokol_libs :: proc() -> bool {
	missing_any := false
	for lib in SOKOL_LIBS {
		for variant in SOKOL_VARIANTS {
			if !os.exists(sokol_lib_path(lib.name, lib.pkg, variant)) {
				missing_any = true
			}
		}
	}
	if !missing_any {
		return true
	}

	os.make_directory_all(SOKOL_GEN_DIR)
	fmt.println("[Setup] Building Sokol static libraries (one-time)...")

	for lib in SOKOL_LIBS {
		// One translation unit per library, mirroring the upstream
		// sokol-odin build script's static library layout.
		tu := fmt.tprintf("%s/%s.c", SOKOL_GEN_DIR, lib.name)
		src := fmt.tprintf("#define %s\n", lib.impl_define)
		for header in lib.pre_includes {
			src = fmt.tprintf("%s#include \"%s\"\n", src, header)
		}
		src = fmt.tprintf("%s#include \"%s.h\"\n", src, lib.name)
		if werr := os.write_entire_file(tu, src); werr != nil {
			fmt.eprintf("[Setup] cannot write %s: %v\n", tu, werr)
			return false
		}

		for variant in SOKOL_VARIANTS {
			lib_path := sokol_lib_path(lib.name, lib.pkg, variant)
			if os.exists(lib_path) {
				continue
			}
			obj := fmt.tprintf("%s/%s_%s.o", SOKOL_GEN_DIR, lib.name, variant)
			// SOKOL_NO_ENTRY: we provide our own main() and call sapp.run()
			// ourselves instead of sokol_app's sokol_main() entry point.
			flags: []string
			if variant == "debug" {
				flags = []string{"cc", "-pthread", "-c", "-g", "-DSOKOL_GLCORE", "-DSOKOL_NO_ENTRY", "-I" + SOKOL_C_DIR, tu, "-o", obj}
			} else {
				flags = []string{"cc", "-pthread", "-c", "-O2", "-DNDEBUG", "-DSOKOL_GLCORE", "-DSOKOL_NO_ENTRY", "-I" + SOKOL_C_DIR, tu, "-o", obj}
			}
			if !run_tool(flags) {
				fmt.eprintf("[Setup] failed to compile %s (%s)\n", lib.name, variant)
				return false
			}
			if !run_tool([]string{"ar", "rcs", lib_path, obj}) {
				fmt.eprintf("[Setup] failed to archive %s (%s)\n", lib.name, variant)
				return false
			}
		}
	}
	fmt.println("[Setup] Sokol libraries ready.")
	return true
}

sokol_lib_path :: proc(name, pkg, variant: string) -> string {
	return fmt.tprintf(SOKOL_PKG_DIR + "/%s/%s_linux_x64_gl_%s.a", pkg, name, variant)
}

run_tool :: proc(args: []string, quiet := false) -> bool {
	desc := os.Process_Desc{command = args}
	// temp-allocated output; borrowed for the duration of this proc only.
	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
	if err != nil {
		fmt.eprintf("[Setup] failed to run %v: %v\n", args[0], err)
		return false
	}
	if !quiet {
		if len(stdout) > 0 {
			fmt.print(string(stdout))
		}
		if len(stderr) > 0 {
			fmt.eprint(string(stderr))
		}
	}
	return state.exit_code == 0
}
