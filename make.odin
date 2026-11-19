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
//     odin run make.odin -file -- windows          # Windows build (cross-build on Linux)
//     odin run make.odin -file -- windows --release
//     odin run make.odin -file -- test             # core unit tests
//     odin run make.odin -file -- text-test        # M05.01–M05.10 native text dependencies
//     odin run make.odin -file -- ligature-test    # M05.09 X11 product ligature configuration
//     odin run make.odin -file -- emoji-test       # M05.10 X11 product color emoji
//     odin run make.odin -file -- unicode-test     # M06 special-character X11 product checks
//     odin run make.odin -file -- clipboard-test   # M06.04/M06.08 X11 clipboard
//     odin run make.odin -file -- ime-test         # M06.07 X11 IME
//     odin run make.odin -file -- typing-test      # M06.09–M06.15 X11 typing/mouse/clipboard/zoom/file-save
//     odin run make.odin -file -- layout-test      # M07.01 X11 column/window dragging
//     odin run make.odin -file -- view-test        # M07.02/M07.06 X11 independent buffers/views
//     odin run make.odin -file -- tag-test         # M07.03 X11 editable/generated tags
//     odin run make.odin -file -- mouse-test       # M07.04 X11 original mouse actions/chords
//     odin run make.odin -file -- look-test        # M07.06 X11 Look expansion and file opening
//     odin run make.odin -file -- directory-test   # M07.07 X11 directory and error windows
//     odin run make.odin -file -- compatibility-test # M07.08 integrated Acme window behavior
//     odin run make.odin -file -- edit-test        # M08.04–M08.06 X11 Edit commands
//     odin run make.odin -file -- builtin-test     # M08.09 X11 window/file commands
//     odin run make.odin -file -- wrap-test        # M07.09 X11 soft wrap and horizontal scrolling
//     odin run make.odin -file -- scroll-test      # M07.10–M07.11 X11 viewport, scrollbar, and line numbers
//     odin run make.odin -file -- autopair-test    # M06.13 X11 enabled/disabled autopair policy
//     odin run make.odin -file -- clipboard-windows-test  # native Windows or Linux/Wine clipboard
//     odin run make.odin -file -- windows-text-test # native Windows fonts/shaping/product rendering
//     odin run make.odin -file -- recovery-test    # M04.08 process-kill recovery
//     odin run make.odin -file -- process-test     # M09.01 process spawning and handle ownership
//     odin run make.odin -file -- bench            # rope/txn bounded benchmarks
//
// The `windows` target builds hammer.exe for windows_amd64. It uses LLVM and
// the normal Windows CRT/SDK on Windows, or mingw-w64 without a CRT on Linux
// (with lld-link and the pinned Sokol C sources, GL backend).
//
// On Linux and Windows this tool also self-configures the Sokol dependency:
// it downloads the pinned Sokol C sources (verified by sha256), checks the
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
when ODIN_OS == .Windows {
	BINARY_PATH :: OUT_DIR + "/" + BINARY_NAME + ".exe"
} else {
	BINARY_PATH :: OUT_DIR + "/" + BINARY_NAME
}

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

RECOVERY_TEST_DIR :: #directory + "/tests/integration/recovery"
RECOVERY_TEST_BINARY :: OUT_DIR + "/recovery_kill_test"
RECOVERY_TEST_HARNESS :: RECOVERY_TEST_DIR + "/kill_harness.py"
PROCESS_TEST_DIR :: #directory + "/tests/unit/process"
PROCESS_TEST_HELPER_DIR :: PROCESS_TEST_DIR + "/helper"
PROCESS_TEST_HARNESS :: PROCESS_TEST_DIR + "/process_harness.py"
when ODIN_OS == .Windows {
	PROCESS_TEST_HELPER :: OUT_DIR + "/process_test_helper.exe"
} else {
	PROCESS_TEST_HELPER :: OUT_DIR + "/process_test_helper"
}

TEXT_TEST_DIR :: #directory + "/tests/integration/textdeps"
TEXT_WINDOWS_TEST_DIR :: #directory + "/tests/integration/text_windows"
TEXT_WINDOWS_PRODUCT_HARNESS :: TEXT_WINDOWS_TEST_DIR + "/product_harness.py"
CLIPBOARD_TEST_DIR :: #directory + "/tests/integration/clipboard"
CLIPBOARD_INTEROP_DRIVER_DIR :: CLIPBOARD_TEST_DIR + "/driver"
CLIPBOARD_INTEROP_DRIVER :: OUT_DIR + "/clipboard_interop_driver"
CLIPBOARD_INTEROP_HARNESS :: CLIPBOARD_TEST_DIR + "/interop_harness.py"
IME_TEST_DIR :: #directory + "/tests/integration/ime"
TYPING_TEST_HARNESS :: #directory + "/tests/integration/typing/x11_harness.py"
LAYOUT_TEST_HARNESS :: #directory + "/tests/integration/layout/x11_harness.py"
VIEW_TEST_HARNESS :: #directory + "/tests/integration/views/x11_harness.py"
TAG_TEST_HARNESS :: #directory + "/tests/integration/tags/x11_harness.py"
MOUSE_TEST_HARNESS :: #directory + "/tests/integration/mouse/x11_harness.py"
LOOK_TEST_HARNESS :: #directory + "/tests/integration/look/x11_harness.py"
DIRECTORY_TEST_HARNESS :: #directory + "/tests/integration/directory/x11_harness.py"
COMPATIBILITY_TEST_HARNESS :: #directory + "/tests/integration/compatibility/x11_harness.py"
EDIT_TEST_HARNESS :: #directory + "/tests/integration/edit/x11_harness.py"
BUILTIN_TEST_HARNESS :: #directory + "/tests/integration/builtins/x11_harness.py"
WRAP_TEST_HARNESS :: #directory + "/tests/integration/wrap/x11_harness.py"
SCROLL_TEST_HARNESS :: #directory + "/tests/integration/scroll/x11_harness.py"
WRAP_SOFT_BINARY :: OUT_DIR + "/hammer-wrap-soft"
WRAP_TRUNCATE_BINARY :: OUT_DIR + "/hammer-wrap-truncate"
AUTOPAIR_TEST_HARNESS :: #directory + "/tests/integration/autopair/x11_harness.py"
AUTOPAIR_ENABLED_BINARY :: OUT_DIR + "/hammer-autopair-on"
AUTOPAIR_DISABLED_BINARY :: OUT_DIR + "/hammer-autopair-off"
LIGATURE_TEST_HARNESS :: #directory + "/tests/integration/ligature/x11_harness.py"
LIGATURE_FIXTURE_FONT :: #directory + "/tests/integration/textdeps/fixtures/FixtureLigature.ttf"
LIGATURE_ENABLED_BINARY :: OUT_DIR + "/hammer-ligatures-on"
LIGATURE_DISABLED_BINARY :: OUT_DIR + "/hammer-ligatures-off"
EMOJI_TEST_HARNESS :: #directory + "/tests/integration/emoji/x11_harness.py"
UNICODE_TEST_HARNESS :: #directory + "/tests/integration/unicode/x11_harness.py"
CLIPBOARD_WINDOWS_TEST_DIR :: #directory + "/tests/integration/clipboard_windows"
CLIPBOARD_WINDOWS_TEST_BINARY :: OUT_DIR + "/clipboard_windows_test.exe"
CLIPBOARD_WINDOWS_INTEROP_HARNESS :: CLIPBOARD_WINDOWS_TEST_DIR + "/interop_harness.py"
FREETYPE_PKG_VERSION :: "26.7.20" // FreeType 2.15.0 libtool/pkg-config version
HARFBUZZ_VERSION :: "12.3.2"
ICU_VERSION :: "78.3"
FONTCONFIG_VERSION :: "2.18.3"
SHADERC_VERSION :: "shaderc-2026.3"

CORE_TEST_PACKAGES := []string {
	"tests/unit/errs",
	"tests/unit/logging",
	"tests/unit/lifecycle",
	"tests/unit/platform",
	"tests/unit/config",
	"tests/unit/coords",
	"tests/unit/dpi",
	"tests/unit/input",
	"tests/unit/mouse",
	"tests/unit/command",
	"tests/unit/address",
	"tests/unit/edit",
	"tests/unit/acme",
	"tests/unit/scroll",
	"tests/unit/directory",
	"tests/unit/ime",
	"tests/unit/editing",
	"tests/unit/keybind",
	"tests/unit/queue",
	"tests/unit/layout",
	"tests/unit/view",
	"tests/unit/tag",
	"tests/unit/glyphcache",
	"tests/unit/chunk",
	"tests/unit/rope",
	"tests/unit/txn",
	"tests/unit/fileid",
	"tests/unit/fileload",
	"tests/unit/filecodec",
	"tests/unit/filesave",
	"tests/unit/filestate",
	"tests/unit/journal",
	"tests/unit/process",
}

// Windows cross-build (M00.03 Windows half): the mingw-w64 import
// libraries are mirrored into a task-owned linker directory as .lib-named
// symlinks. All of this is generated under build/ (gitignored); see
// docs/notes/m00-03-window.md.
WINDOWS_BINARY_PATH :: OUT_DIR + "/hammer.exe"
WINDOWS_SDK_DIR :: OUT_DIR + "/windows-sdk"
WINDOWS_LLD_SHIM :: OUT_DIR + "/lld-link-shim"

// Pinned Sokol C sources (floooh/sokol), the revision tracked by the
// pinned sokol-odin bindings (third_party/sokol, commit ae94aa5).
SOKOL_C_COMMIT :: "93aa187b5d387cc24b7290b3ca3f13f61e139e7c"
SOKOL_C_URL :: "https://codeload.github.com/floooh/sokol/tar.gz/" + SOKOL_C_COMMIT
SOKOL_C_SHA256 :: "3e5a1b365cd221a8bd386a472cc9450eb7a0a6e93ce9a7fe6f86f8eb07a785c9"
SOKOL_C_DIR :: #directory + "/third_party/sokol-c"
SOKOL_X11_IME_PATCH :: #directory + "/third_party/patches/sokol-app-x11-ime.patch"
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

	// M04.08 process-kill recovery integration. The Python controller owns
	// exact-point acknowledgments, SIGKILL, timeouts, and sandbox cleanup.
	if len(args) > 1 && args[1] == "recovery-test" {
		when ODIN_OS == .Linux {
			run_odin([]string {
				"odin",
				"build",
				RECOVERY_TEST_DIR,
				"-vet",
				HAMMER_COLLECTION,
				"-out:" + RECOVERY_TEST_BINARY,
			})
			run_odin([]string{"python3", RECOVERY_TEST_HARNESS, "--binary", RECOVERY_TEST_BINARY}, true)
		} else {
			fmt.eprintln("[Test] recovery-test currently requires a POSIX SIGKILL controller")
			os.exit(1)
		}
		return
	}

	// M05.01 native text bindings: verify exact dependency and shader-tool
	// versions before linking and calling the real Linux libraries.
	if len(args) > 1 && args[1] == "text-test" {
		when ODIN_OS == .Linux {
			if !text_deps_present() {
				os.exit(1)
			}
			run_odin([]string{"odin", "test", TEXT_TEST_DIR, "-vet", HAMMER_COLLECTION})
		} else {
			fmt.eprintln("[Test] text-test currently requires Linux")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "windows-text-test" {
		when ODIN_OS == .Windows {
			run_odin([]string{"odin", "test", TEXT_WINDOWS_TEST_DIR, "-vet", HAMMER_COLLECTION, "-define:ODIN_TEST_THREADS=1"})
			stage_config([]string{"--no-config"})
			windows_main([]string{"--no-config"})
			run_odin([]string{"python", TEXT_WINDOWS_PRODUCT_HARNESS, "--binary", WINDOWS_BINARY_PATH}, true)
		} else {
			fmt.eprintln("[Test] windows-text-test requires native Windows")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "clipboard-test" {
		when ODIN_OS == .Linux {
			run_odin([]string{"xvfb-run", "-a", "odin", "test", CLIPBOARD_TEST_DIR, "-vet", HAMMER_COLLECTION, "-define:ODIN_TEST_THREADS=1"})
			run_odin([]string {
				"odin",
				"build",
				CLIPBOARD_INTEROP_DRIVER_DIR,
				"-vet",
				HAMMER_COLLECTION,
				"-out:" + CLIPBOARD_INTEROP_DRIVER,
			})
			run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				CLIPBOARD_INTEROP_HARNESS,
				"--driver",
				CLIPBOARD_INTEROP_DRIVER,
				"--peer",
				CLIPBOARD_SPIKE_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] clipboard-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "ime-test" {
		when ODIN_OS == .Linux {
			run_odin([]string{"xvfb-run", "-a", "odin", "test", IME_TEST_DIR, "-vet", HAMMER_COLLECTION, "-define:ODIN_TEST_THREADS=1"})
		} else {
			fmt.eprintln("[Test] ime-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "typing-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				TYPING_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
				"--clipboard-peer",
				CLIPBOARD_SPIKE_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] typing-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "layout-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				LAYOUT_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] layout-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "view-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				VIEW_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] view-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "tag-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				TAG_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] tag-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "mouse-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				MOUSE_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
				"--clipboard-peer",
				CLIPBOARD_SPIKE_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] mouse-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "look-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				LOOK_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] look-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "directory-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				DIRECTORY_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] directory-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "compatibility-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				COMPATIBILITY_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] compatibility-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "edit-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				EDIT_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] edit-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "builtin-test" {
		when ODIN_OS == .Linux {
			stage_config(args[2:])
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				BUILTIN_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] builtin-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "wrap-test" {
		when ODIN_OS == .Linux {
			wrap_test_main()
		} else {
			fmt.eprintln("[Test] wrap-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "scroll-test" {
		when ODIN_OS == .Linux {
			scroll_test_main()
		} else {
			fmt.eprintln("[Test] scroll-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "autopair-test" {
		when ODIN_OS == .Linux {
			autopair_test_main()
		} else {
			fmt.eprintln("[Test] autopair-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "ligature-test" {
		when ODIN_OS == .Linux {
			ligature_test_main()
		} else {
			fmt.eprintln("[Test] ligature-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "emoji-test" {
		when ODIN_OS == .Linux {
			stage_config([]string{"--no-config"})
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				EMOJI_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
				"--clipboard-peer",
				CLIPBOARD_SPIKE_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] emoji-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "unicode-test" {
		when ODIN_OS == .Linux {
			stage_config([]string{"--no-config"})
			if !setup_sokol_linux() {
				os.exit(1)
			}
			run_odin([]string {
				"odin",
				"build",
				SRC_DIR,
				SOKOL_COLLECTION,
				"-vet",
				"-out:" + BINARY_PATH,
				"-debug",
			})
			run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
			run_odin([]string {
				"xvfb-run",
				"-a",
				"python3",
				UNICODE_TEST_HARNESS,
				"--binary",
				BINARY_PATH,
				"--clipboard-peer",
				CLIPBOARD_SPIKE_PATH,
			}, true)
		} else {
			fmt.eprintln("[Test] unicode-test currently requires Linux/X11")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "clipboard-windows-test" {
		when ODIN_OS == .Linux || ODIN_OS == .Windows {
			clipboard_windows_main()
		} else {
			fmt.eprintln("[Test] clipboard-windows-test requires Windows or Linux/Wine")
			os.exit(1)
		}
		return
	}

	if len(args) > 1 && args[1] == "process-test" {
		build_process_test_helper()
		run_process_tests()
		return
	}

	// Core unit tests (headless, no Sokol dependency in the core
	// packages; each package tested separately so failures name the
	// owning package). Test packages live under tests/unit and import
	// the source packages through the `hammer` collection.
	if len(args) > 1 && args[1] == "test" {
		build_process_test_helper()
		for pkg in CORE_TEST_PACKAGES {
			fmt.printf("[Test] %s\n", pkg)
			if pkg == "tests/unit/process" {
				run_process_tests()
			} else {
				run_odin([]string{"odin", "test", pkg, "-vet", HAMMER_COLLECTION})
			}
		}
		return
	}

	// M02.08 benchmark run: the rope/txn bounded-benchmark tests with
	// the wall-clock measurements enabled and a single test thread for
	// stable timings (the deterministic structural guards also run in
	// the ordinary `test` target).
	if len(args) > 1 && args[1] == "bench" {
		bench_packages := []string{"tests/unit/rope", "tests/unit/txn"}
		for pkg in bench_packages {
			fmt.printf("[Bench] %s\n", pkg)
			run_odin(
				[]string {
					"odin",
					"test",
					pkg,
					"-vet",
					HAMMER_COLLECTION,
					"-define:ODIN_TEST_BENCHMARKS=true",
					"-define:ODIN_TEST_THREADS=1",
				},
			)
		}
		return
	}

	// M01.02: stage the configuration before every product build.
	stage_config(args[1:])

	when ODIN_OS == .Windows {
		windows_main(args[1:])
		return
	} else when ODIN_OS == .Linux {
		if !setup_sokol_linux() {
			fmt.eprintln("[Build] Sokol setup failed; cannot continue.")
			os.exit(1)
		}
	} else {
		fmt.println(
			"[Build] note: automatic Sokol setup is only implemented on Linux and Windows for now.",
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
	inherit_stdio := false
	switch mode {
	case "run":
		fmt.println("[Build] Running project (Debug)...")
		cmd_args = []string{"odin", "run", SRC_DIR, SOKOL_COLLECTION, "-vet", "-debug"}
		inherit_stdio = true
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

	run_odin(cmd_args, inherit_stdio)
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

wrap_test_main :: proc() {
	if !setup_sokol_linux() {
		os.exit(1)
	}
	defer stage_config([]string{"--no-config"})
	wrap_test_build("soft", WRAP_SOFT_BINARY)
	wrap_test_build("truncate", WRAP_TRUNCATE_BINARY)
	run_odin([]string {
		"xvfb-run",
		"-a",
		"python3",
		WRAP_TEST_HARNESS,
		"--soft",
		WRAP_SOFT_BINARY,
		"--truncate",
		WRAP_TRUNCATE_BINARY,
	}, true)
}

scroll_test_main :: proc() {
	if !setup_sokol_linux() {
		os.exit(1)
	}
	defer stage_config([]string{"--no-config"})
	wrap_test_build("soft", WRAP_SOFT_BINARY)
	wrap_test_build("truncate", WRAP_TRUNCATE_BINARY)
	run_odin([]string {
		"xvfb-run",
		"-a",
		"python3",
		SCROLL_TEST_HARNESS,
		"--soft",
		WRAP_SOFT_BINARY,
		"--truncate",
		WRAP_TRUNCATE_BINARY,
	}, true)
}

wrap_test_build :: proc(mode: string, binary_path: string) {
	config_path := fmt.tprintf("%s/wrap-%s.yaml", OUT_DIR, mode)
	source := fmt.tprintf("wrap: %q\n", mode)
	if err := os.write_entire_file(config_path, transmute([]byte)source); err != nil {
		fmt.eprintf("[Test] cannot stage wrap config: %v\n", err)
		os.exit(1)
	}
	stage_config([]string{fmt.tprintf("--config=%s", config_path)})
	run_odin([]string {
		"odin",
		"build",
		SRC_DIR,
		SOKOL_COLLECTION,
		"-vet",
		fmt.tprintf("-out:%s", binary_path),
		"-debug",
	})
}

autopair_test_main :: proc() {
	if !setup_sokol_linux() {
		os.exit(1)
	}
	defer stage_config([]string{"--no-config"})
	autopair_test_build(true, AUTOPAIR_ENABLED_BINARY)
	autopair_test_build(false, AUTOPAIR_DISABLED_BINARY)
	run_odin([]string{"odin", "build", SPIKE_CLIPBOARD_DIR, "-vet", "-out:" + CLIPBOARD_SPIKE_PATH})
	run_odin([]string {
		"xvfb-run",
		"-a",
		"python3",
		AUTOPAIR_TEST_HARNESS,
		"--enabled",
		AUTOPAIR_ENABLED_BINARY,
		"--disabled",
		AUTOPAIR_DISABLED_BINARY,
		"--clipboard-peer",
		CLIPBOARD_SPIKE_PATH,
	}, true)
}

autopair_test_build :: proc(enabled: bool, binary_path: string) {
	mode := "on" if enabled else "off"
	config_path := fmt.tprintf("%s/autopair-%s.yaml", OUT_DIR, mode)
	source := fmt.tprintf("autopair: %v\n", enabled)
	if err := os.write_entire_file(config_path, transmute([]byte)source); err != nil {
		fmt.eprintf("[Test] cannot stage autopair config: %v\n", err)
		os.exit(1)
	}
	stage_config([]string{fmt.tprintf("--config=%s", config_path)})
	run_odin([]string {
		"odin",
		"build",
		SRC_DIR,
		SOKOL_COLLECTION,
		"-vet",
		fmt.tprintf("-out:%s", binary_path),
		"-debug",
	})
}

ligature_test_main :: proc() {
	if !setup_sokol_linux() {
		os.exit(1)
	}
	defer stage_config([]string{"--no-config"})
	ligature_test_build(true, LIGATURE_ENABLED_BINARY)
	ligature_test_build(false, LIGATURE_DISABLED_BINARY)
	run_odin([]string {
		"xvfb-run",
		"-a",
		"python3",
		LIGATURE_TEST_HARNESS,
		"--enabled",
		LIGATURE_ENABLED_BINARY,
		"--disabled",
		LIGATURE_DISABLED_BINARY,
	}, true)
}

ligature_test_build :: proc(enabled: bool, binary_path: string) {
	mode := "on" if enabled else "off"
	config_path := fmt.tprintf("%s/ligatures-%s.yaml", OUT_DIR, mode)
	source := fmt.tprintf("font_path: %q\nligatures: %v\n", LIGATURE_FIXTURE_FONT, enabled)
	if err := os.write_entire_file(config_path, transmute([]byte)source); err != nil {
		fmt.eprintf("[Test] cannot stage ligature config: %v\n", err)
		os.exit(1)
	}
	stage_config([]string{fmt.tprintf("--config=%s", config_path)})
	run_odin([]string {
		"odin",
		"build",
		SRC_DIR,
		SOKOL_COLLECTION,
		"-vet",
		fmt.tprintf("-out:%s", binary_path),
		"-debug",
	})
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

build_process_test_helper :: proc() {
	run_odin([]string{"odin", "build", PROCESS_TEST_HELPER_DIR, "-vet", "-out:" + PROCESS_TEST_HELPER})
}

run_process_tests :: proc() {
	python := "python3"
	when ODIN_OS == .Windows {
		python = "python"
	}
	run_odin([]string{python, PROCESS_TEST_HARNESS, "--repo", #directory}, true)
}

// run_odin executes an Odin invocation and exits nonzero if the command
// fails. By default stdout/stderr are captured through pipes and replayed
// only after the child exits (fine for one-shot builds). With
// `inherit_stdio` the child writes straight to hammer's own stdout/stderr
// instead, so long-running children stream their output live — without
// this, every log line from the `run` target only appeared once the
// window was closed. os.process_exec can only capture (it asserts the
// desc streams are nil), so this path uses process_start directly.
run_odin :: proc(cmd_args: []string, inherit_stdio := false) {
	if inherit_stdio {
		desc := os.Process_Desc {
			command = cmd_args,
			stdout = os.stdout,
			stderr = os.stderr,
		}
		child, err := os.process_start(desc)
		if err != nil {
			fmt.eprintf("[Build] Failed to execute process: %v\n", err)
			os.exit(1)
		}
		state, werr := os.process_wait(child)
		if werr != nil {
			fmt.eprintf("[Build] Failed to wait for process: %v\n", werr)
			os.exit(1)
		}
		if state.exit_code != 0 {
			fmt.eprintf("[Build] Command exited with code %d\n", state.exit_code)
			os.exit(int(state.exit_code))
		}
		return
	}

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

// --- Native text dependency checks (M05.01, Linux only) -----------------

text_deps_present :: proc() -> bool {
	pins := []struct {
		pkg:     string,
		version: string,
		exact:   string,
	} {
		{"freetype2", FREETYPE_PKG_VERSION, "--exact-version=" + FREETYPE_PKG_VERSION},
		{"harfbuzz", HARFBUZZ_VERSION, "--exact-version=" + HARFBUZZ_VERSION},
		{"icu-uc", ICU_VERSION, "--exact-version=" + ICU_VERSION},
		{"fontconfig", FONTCONFIG_VERSION, "--exact-version=" + FONTCONFIG_VERSION},
	}
	for pin in pins {
		if !run_tool([]string{"pkg-config", pin.exact, pin.pkg}, true) {
			fmt.eprintf("[Test] required %s %s (pkg-config exact-version check failed)\n", pin.pkg, pin.version)
			return false
		}
	}
	version, ok := tool_output([]string{"glslc", "--version"})
	if !ok || !strings.has_prefix(version, SHADERC_VERSION + "\n") {
		fmt.eprintf("[Test] required %s (glslc --version mismatch)\n", SHADERC_VERSION)
		return false
	}
	fmt.printf(
		"[Setup] pins: FreeType 2.15.0 (%s), HarfBuzz %s, ICU %s, fontconfig %s, %s\n",
		FREETYPE_PKG_VERSION,
		HARFBUZZ_VERSION,
		ICU_VERSION,
		FONTCONFIG_VERSION,
		SHADERC_VERSION,
	)
	return true
}

// --- Sokol setup (Linux only) -----------------------------------------

setup_sokol_linux :: proc() -> bool {
	if !text_deps_present() {
		return false
	}
	if !sokol_headers_present() {
		fmt.println("[Setup] Sokol C headers not found; downloading the pinned revision...")
		if !fetch_sokol_headers() {
			return false
		}
	}
	patched, patch_ok := patch_sokol_x11_ime()
	if !patch_ok {
		return false
	}
	if patched {
		for variant in SOKOL_VARIANTS {
			os.remove(sokol_lib_path("sokol_app", "app", variant))
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

patch_sokol_x11_ime :: proc() -> (changed, ok: bool) {
	data, err := os.read_entire_file(SOKOL_C_DIR + "/sokol_app.h", context.temp_allocator)
	if err != nil {
		fmt.eprintf("[Setup] cannot inspect Sokol X11 IME hook: %v\n", err)
		return false, false
	}
	if strings.contains(string(data), "hammer_sapp_x11_set_event_filter") {
		return false, true
	}
	fmt.println("[Setup] Applying the pinned Sokol X11 IME pre-dispatch hook...")
	if !run_tool([]string {
		"patch", "--no-backup-if-mismatch", "-d", SOKOL_C_DIR, "-p1", "-i", SOKOL_X11_IME_PATCH,
	}, true) {
		fmt.eprintln("[Setup] failed to apply the Sokol X11 IME patch")
		return false, false
	}
	return true, true
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

	// Sokol links X11, Xi, Xcursor and GL; DPI monitor tracking links Xrandr.
	libs := []string{"libX11.so", "libXi.so", "libXcursor.so", "libGL.so", "libXrandr.so"}
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
		"[Setup] Gentoo: emerge -av x11-libs/libX11 x11-libs/libXi x11-libs/libXcursor x11-libs/libXrandr media-libs/mesa sys-devel/binutils",
	)
	fmt.eprintln(
		"[Setup] Debian/Ubuntu: apt install libx11-dev libxi-dev libxcursor-dev libxrandr-dev libgl1-mesa-dev build-essential",
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

// --- Native/cross Windows build (M00.03 Windows half) --------------------

// Linux cross-builds link MinGW's Sokol objects without a CRT. Native
// Windows uses clang-cl and the normal Windows CRT/SDK instead.
WINDOWS_SYSTEM_LIBS := []string {
	"user32.lib",
	"kernel32.lib",
	"gdi32.lib",
	"shell32.lib",
	"ucrtbase.lib",
	"libgcc.lib",
	"mingwex.lib",
}

windows_toolchain :: proc() -> (cc, ar: string) {
	when ODIN_OS == .Windows {
		return "clang-cl", "llvm-ar"
	} else {
		return "x86_64-w64-mingw32-gcc", "x86_64-w64-mingw32-ar"
	}
}

windows_linker_flags :: proc() -> string {
	when ODIN_OS == .Windows {
		return ""
	}
	lib_flags := "/libpath:" + WINDOWS_SDK_DIR
	for lib in WINDOWS_SYSTEM_LIBS {
		lib_flags = fmt.tprintf("%s %s", lib_flags, lib)
	}
	return lib_flags
}

clipboard_windows_main :: proc() {
	if !setup_windows() {
		fmt.eprintln("[Test] Windows clipboard test setup failed")
		os.exit(1)
	}
	cmd_args: [dynamic]string
	defer delete(cmd_args)
	append(&cmd_args, "odin", "build", CLIPBOARD_WINDOWS_TEST_DIR)
	append(&cmd_args, "-target:windows_amd64", "-linker:lld")
	when ODIN_OS != .Windows {
		append(&cmd_args, "-ignore-vs-search", "-no-crt", "-no-thread-local")
	}
	append(&cmd_args, "-vet", HAMMER_COLLECTION)
	if lib_flags := windows_linker_flags(); lib_flags != "" {
		append(&cmd_args, fmt.tprintf("-extra-linker-flags:%s", lib_flags))
	}
	append(&cmd_args, "-out:" + CLIPBOARD_WINDOWS_TEST_BINARY)
	run_odin(cmd_args[:])
	when ODIN_OS == .Windows {
		run_odin([]string{CLIPBOARD_WINDOWS_TEST_BINARY}, true)
		run_odin([]string {
			"python",
			CLIPBOARD_WINDOWS_INTEROP_HARNESS,
			"--binary",
			CLIPBOARD_WINDOWS_TEST_BINARY,
		}, true)
	} else {
		run_odin([]string{"xvfb-run", "-a", "env", "WINEDEBUG=-all", "wine", CLIPBOARD_WINDOWS_TEST_BINARY}, true)
		run_odin([]string {
			"xvfb-run",
			"-a",
			"python3",
			CLIPBOARD_WINDOWS_INTEROP_HARNESS,
			"--binary",
			CLIPBOARD_WINDOWS_TEST_BINARY,
		}, true)
	}
}

// windows_main builds hammer.exe natively on Windows and cross-builds it on
// Linux. Modes mirror the normal build: debug by default, run, or --release.
windows_main :: proc(args: []string) {
	when ODIN_OS == .Windows {
		fmt.println("[Build] Native Windows build (windows_amd64, Sokol GL)...")
	} else {
		fmt.println("[Build] Windows cross-build (windows_amd64, Sokol GL)...")
	}
	if !setup_windows() {
		fmt.eprintln("[Build] Windows build setup failed; cannot continue.")
		os.exit(1)
	}

	mode := "debug"
	for arg in args {
		if arg == "run" {
			mode = "run"
		} else if strings.contains(arg, "--release") {
			mode = "release"
		}
	}

	command := "run" if mode == "run" else "build"
	cmd_args: [dynamic]string
	defer delete(cmd_args)
	append(&cmd_args, "odin", command, SRC_DIR)
	append(&cmd_args, "-target:windows_amd64", "-linker:lld")
	when ODIN_OS != .Windows {
		append(&cmd_args, "-ignore-vs-search", "-no-crt", "-no-thread-local")
	}
	append(&cmd_args, SOKOL_COLLECTION)
	append(&cmd_args, "-define:SOKOL_USE_GL=true")
	if lib_flags := windows_linker_flags(); lib_flags != "" {
		append(&cmd_args, fmt.tprintf("-extra-linker-flags:%s", lib_flags))
	}
	append(&cmd_args, "-vet")
	if mode == "release" {
		fmt.println("[Build] Building project (Release) -> " + WINDOWS_BINARY_PATH + "...")
		append(&cmd_args, "-o:speed", "-no-bounds-check")
	} else {
		fmt.println("[Build] Building project (Debug) -> " + WINDOWS_BINARY_PATH + "...")
		append(&cmd_args, "-debug")
	}
	append(&cmd_args, "-out:" + WINDOWS_BINARY_PATH)

	run_odin(cmd_args[:], mode == "run")
	when ODIN_OS == .Windows {
		fmt.println("[Build] Native Windows build done -> " + WINDOWS_BINARY_PATH)
	} else {
		fmt.println("[Build] Windows build done. Smoke test under Wine:")
		fmt.println("[Build]   xvfb-run -a env HAMMER_AUTOQUIT_FRAMES=10 wine " + WINDOWS_BINARY_PATH)
	}
}

// setup_windows verifies the native LLVM or cross MinGW toolchain, fetches
// the pinned Sokol sources, builds its static libraries, and locates lld-link.
setup_windows :: proc() -> bool {
	cc, ar := windows_toolchain()
	if !run_tool([]string{cc, "--version"}, true) {
		fmt.eprintf("[Setup] missing %s (install LLVM on Windows or mingw-w64 GCC for cross-builds)\n", cc)
		return false
	}
	if !run_tool([]string{ar, "--version"}, true) {
		fmt.eprintf("[Setup] missing %s (install the matching archiver)\n", ar)
		return false
	}
	if !sokol_headers_present() {
		fmt.println("[Setup] Sokol C headers not found; downloading the pinned revision...")
		if !fetch_sokol_headers() {
			return false
		}
	}

	when ODIN_OS != .Windows {
		kernel32_path, kernel32_ok := tool_output([]string{cc, "-print-file-name=libkernel32.a"})
		if !kernel32_ok || kernel32_path == "" || !os.exists(kernel32_path) {
			fmt.eprintln("[Setup] cannot locate the mingw-w64 import libraries")
			return false
		}
		libgcc_path, libgcc_ok := tool_output([]string{cc, "-print-file-name=libgcc.a"})
		if !libgcc_ok || libgcc_path == "" || !os.exists(libgcc_path) {
			fmt.eprintln("[Setup] cannot locate libgcc.a")
			return false
		}
		if !setup_windows_sdk(kernel32_path, libgcc_path) {
			return false
		}
	}
	if !build_sokol_libs_windows(cc, ar) {
		return false
	}

	lld_path, lld_ok := find_lld_link()
	if !lld_ok {
		fmt.eprintln("[Setup] no native lld-link found. Install one of:")
		fmt.eprintln("[Setup]   - LLVM/LLD (provides lld-link)")
		fmt.eprintln("[Setup]   - a Rust toolchain (rust-lld; auto-discovered under ~/.rustup on Linux)")
		fmt.eprintln("[Setup]   - set ODIN_LLD_PATH to a native lld-link binary")
		return false
	}
	if set_err := os.set_env("ODIN_LLD_PATH", lld_path); set_err != nil {
		fmt.eprintf("[Setup] cannot set ODIN_LLD_PATH: %v\n", set_err)
		return false
	}
	return true
}

// setup_windows_sdk populates WINDOWS_SDK_DIR with .lib-named symlinks to
// the mingw import libraries for the Linux cross-linker.
setup_windows_sdk :: proc(kernel32_path, libgcc_path: string) -> bool {
	lib_dir := strings.trim_suffix(kernel32_path, "/libkernel32.a")
	if lib_dir == kernel32_path {
		fmt.eprintf("[Setup] unexpected libkernel32.a path: %s\n", kernel32_path)
		return false
	}
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
	for entry in entries {
		name := entry.name
		if strings.has_prefix(name, "lib") && strings.has_suffix(name, ".a") {
			link_name := fmt.tprintf("%s.lib", name[len("lib"):len(name)-len(".a")])
			dst := fmt.tprintf("%s/%s", WINDOWS_SDK_DIR, link_name)
			if !stage_windows_library(entry.fullpath, dst) {
				return false
			}
		}
	}

	return stage_windows_library(libgcc_path, WINDOWS_SDK_DIR + "/libgcc.lib")
}

stage_windows_library :: proc(src, dst: string) -> bool {
	if os.exists(dst) {
		return true
	}
	when ODIN_OS == .Windows {
		if err := os.copy_file(dst, src); err != nil {
			fmt.eprintf("[Setup] cannot copy %s to %s: %v\n", src, dst, err)
			return false
		}
	} else {
		if err := os.symlink(src, dst); err != nil {
			fmt.eprintf("[Setup] cannot symlink %s: %v\n", dst, err)
			return false
		}
	}
	return true
}

// build_sokol_libs_windows compiles the pinned Sokol C sources with the
// selected native/cross compiler. A toolchain marker prevents accidentally
// reusing MinGW objects in an MSVC-CRT build, or vice versa.
build_sokol_libs_windows :: proc(cc, ar: string) -> bool {
	os.make_directory_all(SOKOL_GEN_DIR)
	toolchain_marker := SOKOL_GEN_DIR + "/windows-toolchain"
	cache_current := false
	if data, err := os.read_entire_file(toolchain_marker, context.temp_allocator); err == nil {
		cache_current = strings.trim_space(string(data)) == cc
	}
	missing_any := !cache_current
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

	fmt.println("[Setup] Building Sokol Windows static libraries...")

	for lib in SOKOL_LIBS {
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
			if cache_current && os.exists(lib_path) {
				continue
			}
			obj := fmt.tprintf("%s/%s_windows_%s.o", SOKOL_GEN_DIR, lib.name, variant)
			flags: []string
			when ODIN_OS == .Windows {
				if variant == "debug" {
					flags = []string {
						cc,
						"/c",
						"/Z7",
						"/Od",
						"/D_DEBUG",
						"/DSOKOL_GLCORE",
						"/DSOKOL_NO_ENTRY",
						"/I" + SOKOL_C_DIR,
						tu,
						fmt.tprintf("/Fo%s", obj),
					}
				} else {
					flags = []string {
						cc,
						"/c",
						"/O2",
						"/DNDEBUG",
						"/DSOKOL_GLCORE",
						"/DSOKOL_NO_ENTRY",
						"/I" + SOKOL_C_DIR,
						tu,
						fmt.tprintf("/Fo%s", obj),
					}
				}
			} else {
				if variant == "debug" {
					flags = []string {
						cc,
						"-c",
						"-g",
						"-O0",
						"-mwin32",
						"-DSOKOL_GLCORE",
						"-DSOKOL_NO_ENTRY",
						"-I" + SOKOL_C_DIR,
						tu,
						"-o",
						obj,
					}
				} else {
					flags = []string {
						cc,
						"-c",
						"-O2",
						"-DNDEBUG",
						"-mwin32",
						"-DSOKOL_GLCORE",
						"-DSOKOL_NO_ENTRY",
						"-I" + SOKOL_C_DIR,
						tu,
						"-o",
						obj,
					}
				}
			}
			if !run_tool(flags) {
				fmt.eprintf("[Setup] failed to compile %s (%s) for windows\n", lib.name, variant)
				return false
			}
			if !run_tool([]string{ar, "rcs", lib_path, obj}) {
				fmt.eprintf("[Setup] failed to archive %s (%s) for windows\n", lib.name, variant)
				return false
			}
		}
	}
	if werr := os.write_entire_file(toolchain_marker, cc); werr != nil {
		fmt.eprintf("[Setup] cannot record the Sokol toolchain: %v\n", werr)
		return false
	}
	fmt.println("[Setup] Sokol Windows libraries ready.")
	return true
}

sokol_lib_path_windows :: proc(pkg, variant: string) -> string {
	return fmt.tprintf(SOKOL_PKG_DIR + "/%s/sokol_%s_windows_x64_gl_%s.lib", pkg, pkg, variant)
}

// find_lld_link returns ODIN_LLD_PATH, lld-link on PATH, the linker bundled
// with Odin on Windows, or a Linux rust-lld wrapper as a fallback.
find_lld_link :: proc() -> (string, bool) {
	if env, found := os.lookup_env("ODIN_LLD_PATH", context.temp_allocator); found && env != "" && os.exists(env) {
		return env, true
	}
	when ODIN_OS == .Windows {
		if path, path_ok := tool_output([]string{"where.exe", "lld-link"}); path_ok && path != "" {
			return path, true
		}
		if root, root_ok := tool_output([]string{"odin", "root"}); root_ok && root != "" {
			path := fmt.tprintf("%s/bin/lld-link.exe", root)
			if os.exists(path) {
				return path, true
			}
		}
	} else {
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
				if cerr := os.chmod(WINDOWS_LLD_SHIM, {.Read_User, .Write_User, .Execute_User}); cerr != nil {
					fmt.eprintf("[Setup] cannot chmod %s: %v\n", WINDOWS_LLD_SHIM, cerr)
					return "", false
				}
				fmt.printf("[Setup] using rust-lld via generated shim %s\n", WINDOWS_LLD_SHIM)
				return WINDOWS_LLD_SHIM, true
			}
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
