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

platform_set_read_only :: proc(path: string, read_only: bool) -> os.Error {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return err
	}
	defer os.file_info_delete(info, context.temp_allocator)
	mode := info.mode
	if read_only {
		mode -= os.Permissions_Write_All
	} else {
		mode += os.Permissions_Write_All
	}
	return os.chmod(path, mode)
}
