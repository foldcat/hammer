#+build !linux
#+build !windows

package main

import coords "core/coords"
import txn "core/txn"

Text_Hit :: struct {
	offset:   int,
	affinity: txn.Affinity,
}

text_hit_test :: proc(pos: coords.Logical_Point, clamp_to_visible: bool) -> (Text_Hit, bool) {
	return {}, false
}
