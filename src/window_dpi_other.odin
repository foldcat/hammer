#+build !linux

package main

import sapp "sokol:app"

platform_dpi_scale :: proc() -> f32 {
	return sapp.dpi_scale()
}
