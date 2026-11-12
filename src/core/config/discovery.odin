// Config file discovery: where the build tool looks for the trusted
// user config.
//
// Trust boundary (SPECS.md §14.4): only the paths below are ever read.
// Project-local configs (e.g. a file inside a repository being edited)
// are never discovered, only ever passed explicitly via `--config`.
// `--no-config` skips discovery entirely and stages the built-in
// defaults.
//
// Allocation discipline: environment variables are read into stack
// buffers (`os.get_env` with a `[]u8`), so discovery itself allocates
// only the returned `path` (owned by the caller). No scratch-arena
// usage.
package config

import "core:os"
import "core:strings"

import errs "../errs"

// Discover_Result describes what discovery found. A non-ok `err` means
// an *explicitly requested* file does not exist and the build must
// fail; "not found" with no error means defaults apply.
Discover_Result :: struct {
	found: bool, // false: nothing discovered; defaults apply
	path: string, // owned; caller frees with delete
	err: errs.Error, // non-ok: explicit path missing; build must fail
}

// MAX_ENV_VALUE bounds the stack buffers used to read environment
// variables. Real values (config paths, XDG dirs, APPDATA) are far
// below this; anything longer is treated as absent.
MAX_ENV_VALUE :: 4096

// discover resolves the config source in precedence order:
//
//   1. `explicit_path` (the make.odin --config flag) — must exist.
//   2. The `HAMMER_CONFIG` environment variable — must exist.
//   3. The per-user config path: %APPDATA%/hammer/config.yaml on
//      Windows, $XDG_CONFIG_HOME/hammer/config.yaml (or
//      ~/.config/hammer/config.yaml) elsewhere — optional.
//   4. Nothing found: defaults apply.
//
// `no_config` (the --no-config flag) skips everything.
//
// Ownership: the returned `path` is an owned string allocated with
// `allocator`; the caller frees it with `delete`.
discover :: proc(explicit_path := "", no_config := false, allocator := context.allocator) -> Discover_Result {
	if no_config {
		return Discover_Result{}
	}
	if explicit_path != "" {
		if !os.exists(explicit_path) {
			return Discover_Result{err = errs.newf(.Invalid_Input, "config: %s does not exist", explicit_path)}
		}
		return Discover_Result{found = true, path = strings.clone(explicit_path, allocator)}
	}
	env_buf: [MAX_ENV_VALUE]u8
	if env_path := os.get_env(env_buf[:], "HAMMER_CONFIG"); env_path != "" {
		if !os.exists(env_path) {
			return Discover_Result{err = errs.newf(.Invalid_Input, "config: HAMMER_CONFIG points at %s, which does not exist", env_path)}
		}
		return Discover_Result{found = true, path = strings.clone(env_path, allocator)}
	}
	if user_path, ok := user_config_path(allocator); ok {
		return Discover_Result{found = true, path = user_path}
	}
	return Discover_Result{}
}

// user_config_path returns the per-user config file path when it
// exists. The result is owned (allocated with `allocator`); a "not
// found" result allocates nothing.
user_config_path :: proc(allocator := context.allocator) -> (string, bool) {
	env_buf: [MAX_ENV_VALUE]u8
	when ODIN_OS == .Windows {
		if base := os.get_env(env_buf[:], "APPDATA"); base != "" {
			path := strings.concatenate([]string{base, "/hammer/config.yaml"}, allocator)
			if os.exists(path) {
				return path, true
			}
			delete(path, allocator)
		}
	} else {
		// base borrows from env_buf for the XDG path; the home-derived
		// path is owned. Either way it only needs to outlive the
		// concatenation below (the concatenation copies).
		base := os.get_env(env_buf[:], "XDG_CONFIG_HOME")
		base_owned := false
		if base == "" {
			if home := os.get_env(env_buf[:], "HOME"); home != "" {
				base = strings.concatenate([]string{home, "/.config"}, allocator)
				base_owned = true
			}
		}
		defer if base_owned {
			delete(base, allocator)
		}
		if base != "" {
			path := strings.concatenate([]string{base, "/hammer/config.yaml"}, allocator)
			if os.exists(path) {
				return path, true
			}
			delete(path, allocator)
		}
	}
	return "", false
}
