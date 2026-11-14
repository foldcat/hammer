package filesave

import "core:os"
import "core:sys/linux"

platform_attributes :: proc(file: ^os.File) -> (Existing_Attributes, os.Error) {
	stat: linux.Statx
	errno := linux.statx(linux.Fd(os.fd(file)), "", {.EMPTY_PATH}, {.NLINK, .MODE}, &stat)
	if errno != .NONE {
		return {}, os.Platform_Error(errno)
	}
	return Existing_Attributes {
		links = int(stat.nlink),
		permissions = transmute(os.Permissions)(transmute(u32)stat.mode & 0o7777),
	}, nil
}
