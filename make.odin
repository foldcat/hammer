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
//     odin run make.odin -file -- windows          # M00.03 Windows cross-build
//     odin run make.odin -file -- windows --release
//     odin run make.odin -file -- test             # core unit tests
//
// The `windows` target cross-builds hammer.exe for windows_amd64 from
// Linux (mingw-w64 + lld-link + the pinned Sokol C sources, GL backend);
// the binary is validated under Wine. See docs/m00-03-window.md.
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

import config "src/core/config"
import errs "src/core/errs"

SRC_DIR :: #directory + "/src"
OUT_DIR :: #directory + "/build"
BINARY_NAME :: "hammer"
BINARY_PATH :: OUT_DIR + "/" + BINARY_NAME

// M01.02 generated configuration package: make.odin stages the trusted
// user config into this file before every build (see stage_config).
GENERATED_CONFIG_PATH :: SRC_DIR + "/config/generated/generated.odin"

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

// Core packages covered by the `test` target. All are backend-free:
// the M01 acceptance rule "no dependency-specific code leaks into the
// core" is enforced simply by this list never needing the Sokol
// collection to build. Test packages live outside src/ (tests/unit) so
// they are never compiled into product builds; the `hammer` collection
// maps them back onto the source packages under test.
HAMMER_COLLECTION :: "-collection:hammer=" + SRC_DIR

CORE_TEST_PACKAGES := []string {
	"tests/unit/errs",
	"tests/unit/logging",
	"tests/unit/lifecycle",
	"tests/unit/platform",
	"tests/unit/config",
	"tests/unit/coords",
	"tests/unit/input",
	"tests/unit/queue",
	"tests/unit/layout",
}

// Windows cross-build (M00.03 Windows half): the mingw-w64 import
// libraries, mirrored into a task-owned "Windows SDK root" as .lib-named
// symlinks, serve as the -windows-sdk-root for cross-linking. All of this
// is generated under build/ (gitignored); see docs/m00-03-window.md.
WINDOWS_BINARY_PATH :: OUT_DIR + "/hammer.exe"
WINDOWS_SDK_DIR :: OUT_DIR + "/windows-sdk"
WINDOWS_LLD_SHIM :: OUT_DIR + "/lld-link-shim"

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

	// M01.02: --init-config <path> writes a commented example config.
	if len(args) > 1 && args[1] == "--init-config" {
		path := "config.yaml"
		if len(args) > 2 {
			path = args[2]
		}
		init_config(path)
		return
	}

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

	// M00.03 Windows half: cross-build hammer.exe for windows_amd64.
	if len(args) > 1 && args[1] == "windows" {
		stage_config(args[2:])
		windows_main(args[2:])
		return
	}

	// Core unit tests (headless, no Sokol dependency in the core
	// packages; each package tested separately so failures name the
	// owning package). Test packages live under tests/unit and import
	// the source packages through the `hammer` collection.
	if len(args) > 1 && args[1] == "test" {
		for pkg in CORE_TEST_PACKAGES {
			fmt.printf("[Test] %s\n", pkg)
			run_odin([]string{"odin", "test", pkg, "-vet", HAMMER_COLLECTION})
		}
		return
	}

	// M01.02: stage the configuration before every product build.
	stage_config(args[1:])

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

// --- Configuration staging (M01.02) ------------------------------------

// stage_config resolves the trusted user config (--config / HAMMER_CONFIG
// / the per-user path / built-in defaults), validates it, and regenerates
// the staged configuration package compiled into the product. Any error
// fails the build: a malformed config must never be silently ignored,
// and the trust boundary (SPECS.md §14.4) is enforced by `discover`.
stage_config :: proc(args: []string) {
	explicit := ""
	no_config := false
	for arg in args {
		if strings.has_prefix(arg, "--config=") {
			explicit = strings.trim_prefix(arg, "--config=")
		} else if arg == "--no-config" {
			no_config = true
		}
	}

	res := config.discover(explicit, no_config)
	if !errs.ok(res.err) {
		config_fail(res.err)
	}
	defer delete(res.path)

	r: config.Resolved
	// NOTE: this defer must be proc-scoped, not block-scoped — Odin
	// defers run at the end of their block, and `r` is consumed after
	// the if/else below (describe + write_staged).
	defer config.resolved_destroy(&r)
	if res.found {
		resolved, resolve_err := config.resolve_from_path(res.path)
		if !errs.ok(resolve_err) {
			config_fail(resolve_err)
		}
		r = resolved
		fmt.printf("[Config] using %s\n", res.path)
	} else {
		builtin, builtin_err := config.builtin()
		if !errs.ok(builtin_err) {
			config_fail(builtin_err)
		}
		r = builtin
		fmt.println(
			"[Config] no config file found; staging built-in defaults (--init-config <path> writes an example)",
		)
	}
	desc := config.describe(r)
	fmt.printf("[Config] %v\n", desc)
	delete(desc)

	if werr := config.write_staged(r, GENERATED_CONFIG_PATH); !errs.ok(werr) {
		config_fail(werr)
	}
}

// config_fail reports a configuration error and exits. The described
// text is an owned allocation (context.allocator), freed before exit —
// no scratch-arena accumulation (AGENTS.md §10.5).
config_fail :: proc(e: errs.Error) {
	desc := errs.describe(e, context.allocator)
	fmt.eprintf("[Config] %v\n", desc)
	delete(desc, context.allocator)
	os.exit(1)
}

// init_config writes the commented example config to `path`. An existing
// file is never overwritten (AGENTS.md §6.1).
init_config :: proc(path: string) {
	if os.exists(path) {
		fmt.eprintf("[Config] %s already exists; not overwriting\n", path)
		os.exit(1)
	}
	example := #directory + "/configs/example.yaml"
	data, read_err := os.read_entire_file(example, context.allocator)
	defer delete(data, context.allocator)
	if read_err != nil {
		fmt.eprintf("[Config] cannot read the example config: %v\n", read_err)
		os.exit(1)
	}
	if werr := os.write_entire_file(path, data); werr != nil {
		fmt.eprintf("[Config] cannot write %s: %v\n", path, werr)
		os.exit(1)
	}
	fmt.printf("[Config] wrote example config to %s\n", path)
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

// --- Windows cross-build (M00.03 Windows half) ---------------------------

// Win32 + CRT libraries the Sokol GL static libraries resolve against at
// final link. They are passed as plain linker inputs rather than
// /defaultlib flags: the lld-link used here honors only the last
// /defaultlib argument (verified; see docs/m00-03-window.md §Windows).
WINDOWS_SYSTEM_LIBS := []string {
	"user32.lib",
	"kernel32.lib",
	"gdi32.lib",
	"shell32.lib",
	"ucrtbase.lib", // UCRT: malloc/free/memcpy/fputs/abort/... from the mingw build
	"libgcc.lib", // ___chkstk_ms and friends (symlinked into the SDK root)
	"mingwex.lib", // _assert from the mingw build (lib prefix stripped like the other imports)
}

// windows_main cross-builds hammer.exe for windows_amd64. Modes: debug by
// default, release with --release (mirrors the Linux build modes).
windows_main :: proc(args: []string) {
	fmt.println("[Build] Windows cross-build (windows_amd64, Sokol GL)...")
	if !setup_windows() {
		fmt.eprintln("[Build] Windows cross-build setup failed; cannot continue.")
		os.exit(1)
	}

	mode := "debug"
	for arg in args {
		if strings.contains(arg, "--release") {
			mode = "release"
			break
		}
	}

	lib_flags := "/libpath:" + WINDOWS_SDK_DIR
	for lib in WINDOWS_SYSTEM_LIBS {
		lib_flags = fmt.tprintf("%s %s", lib_flags, lib)
	}

	cmd_args: [dynamic]string
	append(&cmd_args, "odin", "build", SRC_DIR)
	append(&cmd_args, "-target:windows_amd64")
	append(&cmd_args, "-linker:lld")
	append(&cmd_args, "-windows-sdk-root:" + WINDOWS_SDK_DIR)
	append(&cmd_args, "-no-crt", "-no-thread-local")
	append(&cmd_args, SOKOL_COLLECTION)
	append(&cmd_args, "-define:SOKOL_USE_GL=true")
	append(&cmd_args, fmt.tprintf("-extra-linker-flags:%s", lib_flags))
	append(&cmd_args, "-vet")
	if mode == "release" {
		fmt.println("[Build] Building project (Release) -> " + WINDOWS_BINARY_PATH + "...")
		append(&cmd_args, "-o:speed", "-no-bounds-check")
	} else {
		fmt.println("[Build] Building project (Debug) -> " + WINDOWS_BINARY_PATH + "...")
		append(&cmd_args, "-debug")
	}
	append(&cmd_args, "-out:" + WINDOWS_BINARY_PATH)

	run_odin(cmd_args[:])
	fmt.println("[Build] Windows build done. Smoke test under Wine:")
	fmt.println("[Build]   xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 wine " + WINDOWS_BINARY_PATH)
}

// setup_windows verifies the mingw-w64 toolchain, assembles the Windows SDK
// root, builds the Sokol Windows static libraries, and locates a native
// lld-link (exported to the odin subprocess via ODIN_LLD_PATH).
setup_windows :: proc() -> bool {
	if !run_tool([]string{"x86_64-w64-mingw32-gcc", "--version"}, true) {
		fmt.eprintln("[Setup] missing x86_64-w64-mingw32-gcc (Gentoo: cross-x86_64-w64-mingw32/gcc)")
		return false
	}
	if !run_tool([]string{"x86_64-w64-mingw32-ar", "--version"}, true) {
		fmt.eprintln("[Setup] missing x86_64-w64-mingw32-ar (Gentoo: cross-x86_64-w64-mingw32/binutils)")
		return false
	}

	sysroot, sysroot_ok := tool_output([]string{"x86_64-w64-mingw32-gcc", "-print-sysroot"})
	if !sysroot_ok || sysroot == "" {
		fmt.eprintln("[Setup] cannot determine the mingw-w64 sysroot")
		return false
	}
	libgcc_path, libgcc_ok := tool_output([]string{"x86_64-w64-mingw32-gcc", "-print-file-name=libgcc.a"})
	if !libgcc_ok || libgcc_path == "" || !os.exists(libgcc_path) {
		fmt.eprintln("[Setup] cannot locate libgcc.a")
		return false
	}

	if !setup_windows_sdk(sysroot, libgcc_path) {
		return false
	}
	if !build_sokol_libs_windows() {
		return false
	}

	lld_path, lld_ok := find_lld_link()
	if !lld_ok {
		fmt.eprintln("[Setup] no native lld-link found. Install one of:")
		fmt.eprintln("[Setup]   - llvm-core/lld (provides lld-link)")
		fmt.eprintln("[Setup]   - a Rust toolchain (rust-lld; auto-discovered under ~/.rustup)")
		fmt.eprintln("[Setup]   - set ODIN_LLD_PATH to a native lld-link binary")
		return false
	}
	// The odin subprocess execs this path as its linker.
	if set_err := os.set_env("ODIN_LLD_PATH", lld_path); set_err != nil {
		fmt.eprintf("[Setup] cannot set ODIN_LLD_PATH: %v\n", set_err)
		return false
	}
	return true
}

// setup_windows_sdk populates WINDOWS_SDK_DIR with .lib-named symlinks to
// the mingw import libraries. Odin's -windows-sdk-root scans this tree
// case-insensitively to resolve bare system library names, and lld-link
// resolves the plain names through /libpath. Existing symlinks are reused
// so repeated runs stay cheap.
setup_windows_sdk :: proc(sysroot, libgcc_path: string) -> bool {
	lib_dir := fmt.tprintf("%s/x86_64-w64-mingw32/lib", sysroot)
	os.make_directory_all(WINDOWS_SDK_DIR)

	dir, derr := os.open(lib_dir)
	if derr != nil {
		fmt.eprintf("[Setup] cannot open %s: %v\n", lib_dir, derr)
		return false
	}
	defer os.close(dir)
	entries, rerr := os.read_all_directory(dir, context.temp_allocator)
	if rerr != nil {
		fmt.eprintf("[Setup] cannot read %s: %v\n", lib_dir, rerr)
		return false
	}
	prefix := "lib"
	suffix := ".a"
	for entry in entries {
		name := entry.name
		if strings.has_prefix(name, prefix) && strings.has_suffix(name, suffix) {
			link_name := fmt.tprintf("%s.lib", name[len(prefix):len(name)-len(suffix)])
			dst := fmt.tprintf("%s/%s", WINDOWS_SDK_DIR, link_name)
			if !os.exists(dst) {
				if lerr := os.symlink(entry.fullpath, dst); lerr != nil {
					fmt.eprintf("[Setup] cannot symlink %s: %v\n", dst, lerr)
					return false
				}
			}
		}
	}

	// libgcc.a (___chkstk_ms and friends) lives outside the import lib dir.
	libgcc_dst := WINDOWS_SDK_DIR + "/libgcc.lib"
	if !os.exists(libgcc_dst) {
		if lerr := os.symlink(libgcc_path, libgcc_dst); lerr != nil {
			fmt.eprintf("[Setup] cannot symlink %s: %v\n", libgcc_dst, lerr)
			return false
		}
	}
	return true
}

// build_sokol_libs_windows compiles the pinned Sokol C sources for
// windows_amd64 with the mingw-w64 compiler and archives them as the .lib
// files the sokol-odin bindings expect for the GL variant
// (third_party/sokol/sokol/<pkg>/sokol_<pkg>_windows_x64_gl_<variant>.lib,
// gitignored by the submodule). GL backend only for now; the D3D11 variant
// is a recorded follow-up (docs/m00-03-window.md).
build_sokol_libs_windows :: proc() -> bool {
	missing_any := false
	for lib in SOKOL_LIBS {
		for variant in SOKOL_VARIANTS {
			if !os.exists(sokol_lib_path_windows(lib.pkg, variant)) {
				missing_any = true
			}
		}
	}
	if !missing_any {
		return true
	}

	os.make_directory_all(SOKOL_GEN_DIR)
	fmt.println("[Setup] Building Sokol Windows static libraries (one-time)...")

	for lib in SOKOL_LIBS {
		// Same translation unit as the Linux build: the impl defines are
		// resolved per-target at compile time.
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
			lib_path := sokol_lib_path_windows(lib.pkg, variant)
			if os.exists(lib_path) {
				continue
			}
			obj := fmt.tprintf("%s/%s_windows_%s.o", SOKOL_GEN_DIR, lib.name, variant)
			flags: []string
			if variant == "debug" {
				flags = []string {
					"x86_64-w64-mingw32-gcc",
					"-c",
					"-g",
					"-O0",
					"-DSOKOL_GLCORE",
					"-DSOKOL_NO_ENTRY",
					"-I" + SOKOL_C_DIR,
					tu,
					"-o",
					obj,
				}
			} else {
				flags = []string {
					"x86_64-w64-mingw32-gcc",
					"-c",
					"-O2",
					"-DNDEBUG",
					"-DSOKOL_GLCORE",
					"-DSOKOL_NO_ENTRY",
					"-I" + SOKOL_C_DIR,
					tu,
					"-o",
					obj,
				}
			}
			if !run_tool(flags) {
				fmt.eprintf("[Setup] failed to compile %s (%s) for windows\n", lib.name, variant)
				return false
			}
			if !run_tool([]string{"x86_64-w64-mingw32-ar", "rcs", lib_path, obj}) {
				fmt.eprintf("[Setup] failed to archive %s (%s) for windows\n", lib.name, variant)
				return false
			}
		}
	}
	fmt.println("[Setup] Sokol Windows libraries ready.")
	return true
}

sokol_lib_path_windows :: proc(pkg, variant: string) -> string {
	return fmt.tprintf(SOKOL_PKG_DIR + "/%s/sokol_%s_windows_x64_gl_%s.lib", pkg, pkg, variant)
}

// find_lld_link returns the path of a usable native lld-link: the
// ODIN_LLD_PATH env var if set, `lld-link` on PATH, or a generated wrapper
// around a Rust toolchain's rust-lld (-flavor link selects lld-link).
find_lld_link :: proc() -> (string, bool) {
	if env, found := os.lookup_env("ODIN_LLD_PATH", context.temp_allocator); found && env != "" && os.exists(env) {
		return env, true
	}
	if path, path_ok := tool_output([]string{"sh", "-c", "command -v lld-link"}); path_ok && path != "" {
		return path, true
	}
	if home, found := os.lookup_env("HOME", context.temp_allocator); found && home != "" {
		glob := fmt.tprintf("%s/.rustup/toolchains/*/lib/rustlib/*/bin/rust-lld", home)
		rust_path, rust_ok := tool_output([]string{"sh", "-c", fmt.tprintf("ls %s 2>/dev/null | head -n 1", glob)})
		if rust_ok && rust_path != "" {
			shim := fmt.tprintf("#!/bin/sh\n# generated by make.odin\n\nexec \"%s\" -flavor link \"$@\"\n", rust_path)
			if werr := os.write_entire_file(WINDOWS_LLD_SHIM, transmute([]byte)shim); werr != nil {
				fmt.eprintf("[Setup] cannot write %s: %v\n", WINDOWS_LLD_SHIM, werr)
				return "", false
			}
			// The shim is exec'd directly by odin, so it needs the exec bit.
			if cerr := os.chmod(WINDOWS_LLD_SHIM, {.Read_User, .Write_User, .Execute_User}); cerr != nil {
				fmt.eprintf("[Setup] cannot chmod %s: %v\n", WINDOWS_LLD_SHIM, cerr)
				return "", false
			}
			fmt.printf("[Setup] using rust-lld via generated shim %s\n", WINDOWS_LLD_SHIM)
			return WINDOWS_LLD_SHIM, true
		}
	}
	return "", false
}

// tool_output runs a command and returns its stdout trimmed on success.
// The result is borrowed from context.temp_allocator; it is only valid
// until the next scratch reset.
tool_output :: proc(args: []string) -> (string, bool) {
	desc := os.Process_Desc{command = args}
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		return "", false
	}
	return strings.trim_space(string(stdout)), true
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
