package mouse

Look_Path :: struct {
	path: string, // Borrowed from the input string.
	line: int, // One-based; zero means no line suffix.
	col:  int, // One-based scalar column; zero means no column suffix.
}

parse_look_path :: proc(text: string) -> Look_Path {
	result := Look_Path{path = text}
	if text == "" {
		return result
	}
	// A trailing colon is an empty suffix (`file:12:` or `file:12:34:`), as
	// emitted by grep/compiler output like `file:line: message`. Strip it so
	// the preceding number is still recognized. A bare `file:` (nothing after
	// the colon) keeps its colon as part of the path.
	working := text
	if text[len(text) - 1] == ':' {
		working = text[:len(text) - 1]
	}
	last := last_colon(working)
	if last <= 0 || last + 1 >= len(working) {
		return result
	}
	tail, tail_ok := parse_positive_decimal(working[last + 1:])
	if !tail_ok {
		return result
	}
	// A second numeric suffix after an earlier colon is a column address
	// (`path:line:col`). Windows drive letters (`C:\...`) never put digits
	// between the drive colon and the trailing suffix, so the fall-through
	// treats a single trailing number as the line. A preceding colon at
	// position 0 leaves no path before it, so we do not split there either.
	prev := last_colon(working[:last])
	if prev > 0 {
		if line, ok := parse_positive_decimal(working[prev + 1:last]); ok {
			return {path = working[:prev], line = line, col = tail}
		}
	}
	return {path = working[:last], line = tail}
}

last_colon :: proc(text: string) -> int {
	for index := len(text) - 1; index >= 0; index -= 1 {
		if text[index] == ':' {
			return index
		}
	}
	return -1
}

// parse_positive_decimal reads a non-empty, non-zero, overflow-free decimal
// integer. A leading-zero number (e.g. "001") is accepted and normalized.
parse_positive_decimal :: proc(text: string) -> (int, bool) {
	if text == "" {
		return 0, false
	}
	value := u64(0)
	max_int := u64(~uint(0) >> 1)
	for index := 0; index < len(text); index += 1 {
		c := text[index]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		if value > (max_int - digit) / 10 {
			return 0, false
		}
		value = value * 10 + digit
	}
	if value == 0 {
		return 0, false
	}
	return int(value), true
}
