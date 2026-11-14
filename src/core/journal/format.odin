package journal

import "core:encoding/endian"
import "core:hash"

import filecodec "../filecodec"
import fileid "../fileid"

// All persistent fields are fixed-width little-endian values. No Odin struct
// memory is serialized. Format version 1 uses SHA-256 for base content and
// CRC32 for file headers and records.
FILE_MAGIC :: [8]u8{'H', 'M', 'R', 'J', '\r', '\n', 0x1a, '\n'}
HEADER_FIXED_SIZE :: 160
HEADER_TRAILER_SIZE :: 4
RECORD_HEADER_SIZE :: 24
RECORD_TRAILER_SIZE :: 4

Record_Header :: struct {
	payload_length:   u32,
	version:          u32,
	sequence:         u64,
	timestamp_unix_ns: i64,
}

put_u32 :: proc(data: []byte, offset: int, value: u32) {
	endian.put_u32(data[offset:], .Little, value)
}

put_u64 :: proc(data: []byte, offset: int, value: u64) {
	endian.put_u64(data[offset:], .Little, value)
}

put_i64 :: proc(data: []byte, offset: int, value: i64) {
	endian.put_i64(data[offset:], .Little, value)
}

get_u32 :: proc(data: []byte, offset: int) -> u32 {
	value, _ := endian.get_u32(data[offset:], .Little)
	return value
}

get_u64 :: proc(data: []byte, offset: int) -> u64 {
	value, _ := endian.get_u64(data[offset:], .Little)
	return value
}

get_i64 :: proc(data: []byte, offset: int) -> i64 {
	value, _ := endian.get_i64(data[offset:], .Little)
	return value
}

encode_header_fixed :: proc(data: []byte, header: Header, path_length: u32) {
	magic := FILE_MAGIC
	base_hash := header.base_hash
	copy(data[:len(magic)], magic[:])
	put_u32(data, 8, u32(HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE) + path_length)
	put_u32(data, 12, FORMAT_VERSION)
	put_u32(data, 16, u32(header.stamp.id.kind))
	put_u32(data, 20, u32(header.encoding.encoding))
	put_u32(data, 24, u32(header.encoding.bom))
	put_u32(data, 28, u32(header.encoding.newline))
	put_u64(data, 32, header.stamp.id.hi)
	put_u64(data, 40, header.stamp.id.lo)
	put_u64(data, 48, header.stamp.size)
	put_i64(data, 56, header.stamp.mtime_sec)
	put_u32(data, 64, header.stamp.mtime_nsec)
	put_u32(data, 68, 0)
	put_u32(data, 72, path_length)
	put_u32(data, 76, 0)
	copy(data[80:112], base_hash[:])
	put_u64(data, 112, header.session_id)
	put_u64(data, 120, header.process_instance_id)
	put_i64(data, 128, header.created_unix_ns)
	put_u64(data, 136, u64(header.encoding.newlines.lf))
	put_u64(data, 144, u64(header.encoding.newlines.crlf))
	put_u64(data, 152, u64(header.encoding.newlines.cr))
}

decode_header_fixed :: proc(data: []byte) -> (header: Header, path_length: u32, ok: bool) {
	if len(data) != HEADER_FIXED_SIZE {
		return {}, 0, false
	}
	magic := FILE_MAGIC
	for i in 0 ..< len(magic) {
		if data[i] != magic[i] {
			return {}, 0, false
		}
	}
	path_length = get_u32(data, 72)
	header_bytes := u64(get_u32(data, 8))
	if header_bytes != u64(HEADER_FIXED_SIZE + HEADER_TRAILER_SIZE) + u64(path_length) {
		return {}, 0, false
	}
	if get_u32(data, 68) != 0 || get_u32(data, 76) != 0 {
		return {}, 0, false
	}
	id_kind := get_u32(data, 16)
	encoding := get_u32(data, 20)
	bom := get_u32(data, 24)
	newline := get_u32(data, 28)
	if id_kind > u32(fileid.ID_Kind.Windows) ||
		encoding > u32(filecodec.Encoding.UTF32_BE) ||
		bom > u32(filecodec.BOM.UTF32_BE) ||
		newline > u32(filecodec.Newline.Mixed) {
		return {}, 0, false
	}
	lf := get_u64(data, 136)
	crlf := get_u64(data, 144)
	cr := get_u64(data, 152)
	if lf > u64(max(int)) || crlf > u64(max(int)) || cr > u64(max(int)) {
		return {}, 0, false
	}
	header.stamp.id = fileid.File_ID {
		kind = fileid.ID_Kind(id_kind),
		hi = get_u64(data, 32),
		lo = get_u64(data, 40),
	}
	header.stamp.size = get_u64(data, 48)
	header.stamp.mtime_sec = get_i64(data, 56)
	header.stamp.mtime_nsec = get_u32(data, 64)
	if header.stamp.mtime_nsec >= fileid.NSECS_PER_SEC {
		return {}, 0, false
	}
	copy(header.base_hash[:], data[80:112])
	header.encoding = filecodec.Metadata {
		encoding = filecodec.Encoding(encoding),
		bom = filecodec.BOM(bom),
		newline = filecodec.Newline(newline),
		newlines = {lf = int(lf), crlf = int(crlf), cr = int(cr)},
	}
	header.session_id = get_u64(data, 112)
	header.process_instance_id = get_u64(data, 120)
	header.created_unix_ns = get_i64(data, 128)
	return header, path_length, true
}

header_checksum :: proc(fixed: []byte, path: string) -> u32 {
	crc := hash.crc32(fixed)
	return hash.crc32(transmute([]byte)path, crc)
}

encode_record_header :: proc(data: []byte, sequence: u64, timestamp_unix_ns: i64, payload_length: u32) {
	put_u32(data, 0, payload_length)
	put_u32(data, 4, RECORD_VERSION)
	put_u64(data, 8, sequence)
	put_i64(data, 16, timestamp_unix_ns)
}

decode_record_header :: proc(data: []byte) -> Record_Header {
	return Record_Header {
		payload_length = get_u32(data, 0),
		version = get_u32(data, 4),
		sequence = get_u64(data, 8),
		timestamp_unix_ns = get_i64(data, 16),
	}
}

record_checksum :: proc(header: []byte, payload: []byte) -> u32 {
	crc := hash.crc32(header)
	return hash.crc32(payload, crc)
}
