// Bounded glyph cache and CPU atlas pages. Cache owns every page, entry, and
// copied bitmap. Rasterized input pixels are borrowed only during get. Page
// pixel slices are invalidated by any cache mutation. Entries are values.
package glyphcache

import "base:runtime"

import errs "../../core/errs"

MAX_VARIATIONS :: 4
MAX_PIXEL_SIZE :: 256

Variation :: struct {
	tag:   u32,
	value: f32,
}

Render_Mode :: enum u8 {
	Normal = 0,
	Mono   = 1,
}

Key :: struct {
	font_id:         u64,
	face_index:      i32,
	glyph_id:        u32,
	pixel_size:      u32,
	render_mode:     Render_Mode,
	variation_count: u8,
	variations:      [MAX_VARIATIONS]Variation,
}

Metrics :: struct {
	advance_x: i32,
	advance_y: i32,
	bearing_x: i32,
	bearing_y: i32,
}

Rasterized :: struct {
	width:    int,
	height:   int,
	pitch:    int,
	pixels:   []u8,
	metrics:  Metrics,
}

Rasterize_Proc :: proc(user: rawptr, key: Key, allocator: runtime.Allocator) -> (Rasterized, errs.Error)

Rect :: struct {
	x, y:          int,
	width, height: int,
}

Entry :: struct {
	key:     Key,
	page:    int,
	rect:    Rect,
	metrics: Metrics,
}

Options :: struct {
	page_width:  int,
	page_height: int,
	max_pages:   int,
	max_entries: int,
}

Page :: struct {
	width:      int,
	height:     int,
	pixels:     []u8,
	keys:       [dynamic]Key,
	cursor_x:   int,
	cursor_y:   int,
	row_height: int,
	last_used:  u64,
	dirty:      bool,
}

Stats :: struct {
	hits:      u64,
	misses:    u64,
	evictions: u64,
}

Cache :: struct {
	allocator: runtime.Allocator,
	options:   Options,
	entries:   map[Key]Entry,
	pages:     [dynamic]Page,
	tick:      u64,
	stats:     Stats,
}

DEFAULT_OPTIONS :: Options{page_width = 1024, page_height = 1024, max_pages = 4, max_entries = 4096}

init :: proc(cache: ^Cache, options := DEFAULT_OPTIONS, allocator := context.allocator) -> errs.Error {
	cache^ = Cache{allocator = allocator}
	if options.page_width <= 0 || options.page_height <= 0 || options.max_pages <= 0 || options.max_entries <= 0 {
		return errs.new(.Invalid_Input, "glyph cache dimensions and limits must be positive", allocator = allocator)
	}
	if options.page_width > 4096 || options.page_height > 4096 || options.max_pages > 64 || options.max_entries > 65536 {
		return errs.new(.Resource_Limit, "glyph cache limits exceed the supported budget", allocator = allocator)
	}
	cache.options = options
	cache.entries = make(map[Key]Entry, options.max_entries, allocator)
	cache.pages = make([dynamic]Page, 0, options.max_pages, allocator)
	return errs.Error{}
}

destroy :: proc(cache: ^Cache) {
	for page in cache.pages {
		delete(page.pixels, cache.allocator)
		delete(page.keys)
	}
	delete(cache.pages)
	delete(cache.entries)
	cache^ = Cache{}
}

clear :: proc(cache: ^Cache) {
	for page in cache.pages {
		delete(page.pixels, cache.allocator)
		delete(page.keys)
	}
	runtime.clear(&cache.pages)
	runtime.clear(&cache.entries)
	cache.tick = 0
}

get :: proc(cache: ^Cache, key: Key, rasterize: Rasterize_Proc, user: rawptr) -> (Entry, errs.Error) {
	if err := validate_key(key, cache.allocator); !errs.ok(err) {
		return {}, err
	}
	if entry, found := cache.entries[key]; found {
		cache.tick += 1
		cache.pages[entry.page].last_used = cache.tick
		cache.stats.hits += 1
		return entry, errs.Error{}
	}
	if rasterize == nil {
		return {}, errs.new(.Unsupported, "glyph cache has no rasterizer", allocator = cache.allocator)
	}

	bitmap, raster_err := rasterize(user, key, cache.allocator)
	if !errs.ok(raster_err) {
		return {}, raster_err
	}
	if err := validate_bitmap(bitmap, cache.options, cache.allocator); !errs.ok(err) {
		return {}, err
	}
	cache.stats.misses += 1
	cache.tick += 1
	if bitmap.width == 0 || bitmap.height == 0 {
		return Entry{key = key, page = -1, metrics = bitmap.metrics}, errs.Error{}
	}

	page_index, rect, alloc_err := allocate(cache, bitmap.width, bitmap.height)
	if !errs.ok(alloc_err) {
		return {}, alloc_err
	}
	page := &cache.pages[page_index]
	for row in 0 ..< bitmap.height {
		dst_start := (rect.y + row) * page.width + rect.x
		src_start := row * bitmap.pitch
		copy(page.pixels[dst_start:dst_start + bitmap.width], bitmap.pixels[src_start:src_start + bitmap.width])
	}
	page.last_used = cache.tick
	page.dirty = true
	entry := Entry{key = key, page = page_index, rect = rect, metrics = bitmap.metrics}
	append(&page.keys, key)
	cache.entries[key] = entry
	return entry, errs.Error{}
}

page_pixels :: proc(cache: ^Cache, page_index: int) -> []u8 {
	if page_index < 0 || page_index >= len(cache.pages) {
		return nil
	}
	return cache.pages[page_index].pixels
}

page_dirty :: proc(cache: ^Cache, page_index: int) -> bool {
	return page_index >= 0 && page_index < len(cache.pages) && cache.pages[page_index].dirty
}

mark_page_clean :: proc(cache: ^Cache, page_index: int) {
	if page_index >= 0 && page_index < len(cache.pages) {
		cache.pages[page_index].dirty = false
	}
}

entry_count :: proc(cache: ^Cache) -> int {
	return len(cache.entries)
}

validate_key :: proc(key: Key, allocator := context.allocator) -> errs.Error {
	if key.font_id == 0 || key.face_index < 0 || key.pixel_size == 0 || int(key.variation_count) > MAX_VARIATIONS {
		return errs.new(.Invalid_Input, "invalid glyph cache key", allocator = allocator)
	}
	if key.pixel_size > MAX_PIXEL_SIZE {
		return errs.new(.Resource_Limit, "glyph pixel size exceeds the cache budget", allocator = allocator)
	}
	return errs.Error{}
}

validate_bitmap :: proc(bitmap: Rasterized, options: Options, allocator := context.allocator) -> errs.Error {
	if bitmap.width < 0 || bitmap.height < 0 || bitmap.pitch < bitmap.width {
		return errs.new(.Invalid_Input, "rasterizer returned invalid glyph dimensions", allocator = allocator)
	}
	if bitmap.width == 0 || bitmap.height == 0 {
		return errs.Error{}
	}
	if bitmap.width + 2 > options.page_width || bitmap.height + 2 > options.page_height {
		return errs.new(.Resource_Limit, "glyph bitmap does not fit an atlas page", allocator = allocator)
	}
	if bitmap.pitch <= 0 || len(bitmap.pixels) < bitmap.pitch * bitmap.height {
		return errs.new(.Invalid_Input, "rasterizer returned a short glyph bitmap", allocator = allocator)
	}
	return errs.Error{}
}

allocate :: proc(cache: ^Cache, width, height: int) -> (int, Rect, errs.Error) {
	for {
		for _, index in cache.pages {
			if rect, ok := pack_glyph(&cache.pages[index], width, height); ok {
				return index, rect, errs.Error{}
			}
		}
		if len(cache.entries) >= cache.options.max_entries || len(cache.pages) >= cache.options.max_pages {
			if !evict_lru(cache) {
				return 0, {}, errs.new(.Resource_Limit, "glyph cache cannot allocate an atlas page", allocator = cache.allocator)
			}
		}
		if page_index, ok := new_page(cache); ok {
			rect, placed := pack_glyph(&cache.pages[page_index], width, height)
			if placed {
				return page_index, rect, errs.Error{}
			}
			return 0, {}, errs.new(.Internal, "new glyph atlas page could not accept a validated bitmap", allocator = cache.allocator)
		}
	}
}

new_page :: proc(cache: ^Cache) -> (int, bool) {
	index := len(cache.pages)
	for page, i in cache.pages {
		if page.pixels == nil {
			index = i
			break
		}
	}
	page := Page{
		width = cache.options.page_width,
		height = cache.options.page_height,
		pixels = make([]u8, cache.options.page_width * cache.options.page_height, cache.allocator),
		keys = make([dynamic]Key, cache.allocator),
		cursor_x = 1,
		cursor_y = 1,
		dirty = true,
	}
	if index == len(cache.pages) {
		if index >= cache.options.max_pages {
			delete(page.pixels, cache.allocator)
			delete(page.keys)
			return 0, false
		}
		append(&cache.pages, page)
	} else {
		cache.pages[index] = page
	}
	return index, true
}

pack_glyph :: proc(atlas_page: ^Page, width, height: int) -> (Rect, bool) {
	if atlas_page.pixels == nil {
		return {}, false
	}
	x := atlas_page.cursor_x
	y := atlas_page.cursor_y
	row_height := atlas_page.row_height
	if x + width + 1 > atlas_page.width {
		x = 1
		y += row_height + 1
		row_height = 0
	}
	if y + height + 1 > atlas_page.height {
		return {}, false
	}
	atlas_page.cursor_x = x + width + 1
	atlas_page.cursor_y = y
	atlas_page.row_height = max(row_height, height)
	return Rect{x = x, y = y, width = width, height = height}, true
}

evict_lru :: proc(cache: ^Cache) -> bool {
	oldest := -1
	for page, index in cache.pages {
		if page.pixels != nil && (oldest < 0 || page.last_used < cache.pages[oldest].last_used) {
			oldest = index
		}
	}
	if oldest < 0 {
		return false
	}
	page := &cache.pages[oldest]
	for key in page.keys {
		delete_key(&cache.entries, key)
	}
	delete(page.pixels, cache.allocator)
	delete(page.keys)
	page^ = Page{}
	cache.stats.evictions += 1
	return true
}
