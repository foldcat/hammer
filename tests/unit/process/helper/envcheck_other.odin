#+build !linux

package main

// envcheck is unsupported off Linux (/proc/self/environ is Linux-only); the
// inherited-environment test only runs on Linux.
envcheck :: proc() -> int {
	return 2
}
