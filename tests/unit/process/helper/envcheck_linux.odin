#+build linux

package main

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// envcheck reports how many inherited environment entries are malformed — an
// empty string or a name with no '=' separator. It walks the raw environ array
// (not Odin's os.environ, which itself appends a trailing empty entry) so it
// observes exactly what the spawn passed to exec.
envcheck :: proc() -> int {
	total := 0
	malformed := 0
	for posix.environ[total] != nil {
		entry := string(posix.environ[total])
		total += 1
		if entry == "" || strings.index_byte(entry, '=') <= 0 {
			malformed += 1
		}
	}
	fmt.printf("total=%d malformed=%d\n", total, malformed)
	return 0
}
