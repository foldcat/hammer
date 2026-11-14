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
