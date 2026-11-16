package filesave

import "core:os"
import win32 "core:sys/windows"

platform_attributes :: proc(file: ^os.File) -> (Existing_Attributes, os.Error) {
	info: win32.BY_HANDLE_FILE_INFORMATION
	if !win32.GetFileInformationByHandle(win32.HANDLE(os.fd(file)), &info) {
		return {}, os.Platform_Error(win32.GetLastError())
	}
	permissions := os.Permissions_Read_Write_All
	if info.dwFileAttributes & win32.FILE_ATTRIBUTE_READONLY != 0 {
		permissions = os.Permissions_Read_All
	}
	return Existing_Attributes{links = int(info.nNumberOfLinks), permissions = permissions}, nil
}

platform_set_read_only :: proc(path: string, read_only: bool) -> os.Error {
	wide_path := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide_path == nil {
		return os.General_Error.Invalid_File
	}
	attributes := win32.GetFileAttributesW(wide_path)
	if attributes == win32.INVALID_FILE_ATTRIBUTES {
		return os.Platform_Error(win32.GetLastError())
	}
	if read_only {
		attributes |= win32.FILE_ATTRIBUTE_READONLY
	} else {
		attributes &~= win32.FILE_ATTRIBUTE_READONLY
	}
	if !win32.SetFileAttributesW(wide_path, attributes) {
		return os.Platform_Error(win32.GetLastError())
	}
	return nil
}
