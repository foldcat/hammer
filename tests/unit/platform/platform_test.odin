package platform_test

// These tests prove the interface is fully backend-free: a fake
// implementation with no Sokol (or any native) dependency satisfies the
// service and round-trips values through the proc pointers.

import "core:testing"

import platform "hammer:platform"

Test_Data :: struct {
	width, height: i32,
	scale:         f32,
}

fake_framebuffer_size :: proc(user: rawptr) -> (width, height: i32) {
	data := cast(^Test_Data)user
	return data.width, data.height
}

fake_dpi_scale :: proc(user: rawptr) -> f32 {
	return (cast(^Test_Data)user).scale
}

@(test)
test_window_service_roundtrip :: proc(t: ^testing.T) {
	data := Test_Data{width = 1920, height = 1080, scale = 2.0}
	services := platform.Services{
		user = &data,
		window = platform.Window_Service{
			framebuffer_size = fake_framebuffer_size,
			dpi_scale = fake_dpi_scale,
		},
	}

	width, height := services.window.framebuffer_size(services.user)
	testing.expect(t, width == 1920)
	testing.expect(t, height == 1080)
	testing.expect(t, services.window.dpi_scale(services.user) == 2.0)

	// A different instance through the same implementation.
	other := Test_Data{width = 640, height = 480, scale = 1.0}
	width, height = services.window.framebuffer_size(&other)
	testing.expect(t, width == 640)
	testing.expect(t, height == 480)
	testing.expect(t, services.window.dpi_scale(&other) == 1.0)
}
