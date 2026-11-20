#+build !linux

package main

// size is unsupported off Linux; the PTY window-size test only runs on Linux.
size :: proc() -> int {
	return 2
}
