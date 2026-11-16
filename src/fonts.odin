package main

import "core:log"

import errs "core/errs"
import fonts "text/fonts"
import shaping "text/shaping"

font_set: fonts.Set

EMOJI_FAMILIES :: []string{"Noto Color Emoji", "emoji"}

init_fonts :: proc() {
	options: fonts.Options
	for role_index in 0 ..< 3 {
		options.roles[role_index].path = cfg.Font_Path
	}
	options.roles[int(fonts.Role.Body)].families = cfg.Font_Families
	options.roles[int(fonts.Role.Tag)].families = cfg.Tag_Font_Families
	options.roles[int(fonts.Role.Console)].families = cfg.Console_Font_Families
	options.roles[int(fonts.Role.Emoji)].families = EMOJI_FAMILIES

	if err := fonts.init(&font_set, options, permanent()); !errs.ok(err) {
		log.errorf("fonts: %v; continuing without font faces", errs.describe(err))
		errs.destroy(&err)
		return
	}
	roles := [4]fonts.Role{.Body, .Tag, .Console, .Emoji}
	for role in roles {
		selected := fonts.face(&font_set, role)
		if selected == nil {
			if role == .Emoji {
				log.info("fonts: no color emoji face found; using ordinary font fallback")
			} else {
				log.errorf("fonts: %s role has no face after successful initialization", fonts.role_name(role))
			}
			continue
		}
		log.infof("fonts: role=%s family=%q path=%s face_index=%d", fonts.role_name(role), selected.family, selected.path, selected.face_index)
	}
}

product_shaping_fonts :: proc(storage: ^[shaping.MAX_FONTS]shaping.Font) -> []shaping.Font {
	body := fonts.face(&font_set, .Body)
	if body == nil {
		return nil
	}
	storage[0] = {
		font_id = body.cache_id,
		face_index = body.face_index,
		native = body.native,
	}
	count := 1
	emoji := fonts.face(&font_set, .Emoji)
	if emoji != nil && emoji.native != body.native {
		storage[count] = {
			font_id = emoji.cache_id,
			face_index = emoji.face_index,
			native = emoji.native,
		}
		count += 1
	}
	for index in 0 ..< font_set.fallback_count {
		if count >= len(storage) {
			break
		}
		fallback := &font_set.fallbacks[index]
		storage[count] = {
			font_id = fallback.cache_id,
			face_index = fallback.face_index,
			native = fallback.native,
		}
		count += 1
	}
	return storage[:count]
}
