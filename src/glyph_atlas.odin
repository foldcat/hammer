package main

import sg "sokol:gfx"

import errs "core/errs"
import glyphcache "text/glyphcache"

GPU_Glyph_Atlas :: struct {
	images: [dynamic]sg.Image,
}

glyph_atlas_sync :: proc(atlas: ^GPU_Glyph_Atlas, cache: ^glyphcache.Cache) -> errs.Error {
	if !sg.isvalid() {
		return errs.new(.Internal, "cannot sync glyph atlas before Sokol initialization")
	}
	if len(atlas.images) > len(cache.pages) {
		for page_index in len(cache.pages) ..< len(atlas.images) {
			if atlas.images[page_index].id != 0 {
				sg.destroy_image(atlas.images[page_index])
			}
		}
		resize(&atlas.images, len(cache.pages))
	}
	for page_index in 0 ..< len(cache.pages) {
		for len(atlas.images) <= page_index {
			append(&atlas.images, sg.Image{})
		}
		pixels := glyphcache.page_pixels(cache, page_index)
		if pixels == nil {
			if atlas.images[page_index].id != 0 {
				sg.destroy_image(atlas.images[page_index])
				atlas.images[page_index] = sg.Image{}
			}
			continue
		}
		if !glyphcache.page_dirty(cache, page_index) {
			continue
		}
		image := atlas.images[page_index]
		if image.id != 0 {
			sg.destroy_image(image)
		}
		image = sg.make_image({
			width = i32(cache.pages[page_index].width),
			height = i32(cache.pages[page_index].height),
			pixel_format = .R8,
			usage = {write_unsealed = true},
			label = "hammer-glyph-atlas-page",
		})
		atlas.images[page_index] = image
		sg.write_image_unsealed({
			src = {data = {ptr = raw_data(pixels), size = len(pixels)}},
			dst = {image = image},
			size = {width = i32(cache.pages[page_index].width), height = i32(cache.pages[page_index].height), num_slices = 1},
		})
		sg.seal_image(image)
		if sg.query_image_state(image) != .VALID {
			return errs.newf(.Internal, "glyph atlas GPU image %d is invalid", page_index)
		}
		glyphcache.mark_page_clean(cache, page_index)
	}
	return errs.Error{}
}

glyph_atlas_destroy :: proc(atlas: ^GPU_Glyph_Atlas) {
	for image in atlas.images {
		if image.id != 0 {
			sg.destroy_image(image)
		}
	}
	delete(atlas.images)
	atlas^ = GPU_Glyph_Atlas{}
}
