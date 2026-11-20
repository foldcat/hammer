#+build linux

package main

import "core:fmt"
import "core:os"
import "core:sys/linux"

// size reports the terminal window size the child observes via TIOCGWINSZ.
size :: proc() -> int {
	ws := struct {
		row, col, xpixel, ypixel: u16,
	}{}
	ret := linux.ioctl(linux.Fd(os.fd(os.stdout)), linux.TIOCGWINSZ, uintptr(&ws))
	if i64(ret) < 0 {
		fmt.eprintf("winsize error: %d\n", i64(ret))
		return 2
	}
	fmt.printf("cols=%d rows=%d\n", ws.col, ws.row)
	return 0
}
