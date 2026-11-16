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

product_shaping_fonts :: proc(storage: ^[2]shaping.Font) -> []shaping.Font {
	body := fonts.face(&font_set, .Body)
	if body == nil {
		return nil
	}
	storage[0] = {
		font_id = u64(fonts.Role.Body) + 1,
		face_index = body.face_index,
		native = body.native,
	}
	count := 1
	emoji := fonts.face(&font_set, .Emoji)
	if emoji != nil && emoji.native != body.native {
		storage[1] = {
			font_id = u64(fonts.Role.Emoji) + 1,
			face_index = emoji.face_index,
			native = emoji.native,
		}
		count = 2
	}
	return storage[:count]
}
