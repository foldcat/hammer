package main

import "core:log"

import errs "core/errs"
import fonts "text/fonts"

font_set: fonts.Set

init_fonts :: proc() {
	options: fonts.Options
	for role_index in 0 ..< fonts.ROLE_COUNT {
		options.roles[role_index].path = cfg.Font_Path
	}
	options.roles[int(fonts.Role.Body)].families = cfg.Font_Families
	options.roles[int(fonts.Role.Tag)].families = cfg.Tag_Font_Families
	options.roles[int(fonts.Role.Console)].families = cfg.Console_Font_Families

	if err := fonts.init(&font_set, options, permanent()); !errs.ok(err) {
		log.errorf("fonts: %v; continuing without font faces", errs.describe(err))
		errs.destroy(&err)
		return
	}
	roles := [3]fonts.Role{.Body, .Tag, .Console}
	for role in roles {
		selected := fonts.face(&font_set, role)
		if selected == nil {
			log.errorf("fonts: %s role has no face after successful initialization", fonts.role_name(role))
			continue
		}
		log.infof("fonts: role=%s family=%q path=%s face_index=%d", fonts.role_name(role), selected.family, selected.path, selected.face_index)
	}
}
