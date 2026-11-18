package mouse

Look_Path :: struct {
	path: string, // Borrowed from the input string.
	line: int, // One-based; zero means no line suffix.
}

parse_look_path :: proc(text: string) -> Look_Path {
	result := Look_Path{path = text}
	if text == "" {
		return result
	}
	colon := -1
	for index := len(text) - 1; index >= 0; index -= 1 {
		if text[index] == ':' {
			colon = index
			break
		}
	}
	if colon <= 0 || colon + 1 >= len(text) {
		return result
	}
	line := u64(0)
	max_int := u64(~uint(0) >> 1)
	for index := colon + 1; index < len(text); index += 1 {
		c := text[index]
		if c < '0' || c > '9' {
			return result
		}
		digit := u64(c - '0')
		if line > (max_int - digit) / 10 {
			return result
		}
		line = line * 10 + digit
	}
	if line == 0 {
		return result
	}
	return {path = text[:colon], line = int(line)}
}
