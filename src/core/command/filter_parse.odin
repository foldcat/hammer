package command

import "core:strings"

import errs "../errs"

filter_parse_error :: proc(origin: string, line: int, message: string, allocator := context.allocator) -> errs.Error {
	if origin == "" {
		return errs.newf(.Invalid_Input, "filter: line %d: %s", line, message, allocator = allocator)
	}
	return errs.newf(.Invalid_Input, "filter: %s:%d: %s", origin, line, message, allocator = allocator)
}

// filter_parse_definition reads one declarative key/value file. Values borrow
// text and origin until registration clones them. body is a raw, single-line
// value; multi-line programs are deliberately rejected rather than misparsed.
filter_parse_definition :: proc(text, origin: string, scope: Filter_Scope, allocator := context.allocator) -> (Filter_Definition, errs.Error) {
	definition := Filter_Definition{origin = origin, scope = scope}
	if len(text) > MAX_FILTER_BODY_BYTES {
		return {}, errs.newf(.Resource_Limit, "filter: %s exceeds the %d-byte definition budget", origin, MAX_FILTER_BODY_BYTES, allocator = allocator)
	}
	if scope != .User && scope != .Project && scope != .Session {
		return {}, errs.new(.Invalid_Input, "filter: invalid definition scope", allocator = allocator)
	}
	lines, split_err := strings.split_lines(text, allocator)
	if split_err != nil {
		return {}, errs.new(.Resource_Limit, "filter: cannot split definition into lines", allocator = allocator)
	}
	defer delete(lines, allocator)
	seen_name := false
	seen_engine := false
	seen_routing := false
	seen_body := false
	for raw, index in lines {
		line_number := index + 1
		trimmed := strings.trim_space(raw)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		colon := strings.index_byte(trimmed, ':')
		if colon <= 0 {
			return {}, filter_parse_error(origin, line_number, "expected 'key: value'", allocator = allocator)
		}
		key := strings.trim_space(trimmed[:colon])
		value := strings.trim_space(trimmed[colon + 1:])
		switch key {
		case "name":
			if seen_name {
				return {}, filter_parse_error(origin, line_number, "duplicate name", allocator = allocator)
			}
			seen_name = true
			definition.name = value
		case "engine":
			if seen_engine {
				return {}, filter_parse_error(origin, line_number, "duplicate engine", allocator = allocator)
			}
			seen_engine = true
			definition.engine = value
		case "routing":
			if seen_routing {
				return {}, filter_parse_error(origin, line_number, "duplicate routing", allocator = allocator)
			}
			seen_routing = true
			routing, ok := filter_routing_parse(value)
			if !ok {
				return {}, filter_parse_error(origin, line_number, "routing must be replace-selection, output-window, or discard", allocator = allocator)
			}
			definition.routing = routing
		case "body":
			if seen_body {
				return {}, filter_parse_error(origin, line_number, "duplicate body", allocator = allocator)
			}
			seen_body = true
			definition.body = value
		case:
			return {}, filter_parse_error(origin, line_number, "unknown key", allocator = allocator)
		}
	}
	if !seen_name || !seen_engine || !seen_routing || !seen_body {
		return {}, filter_parse_error(origin, len(lines), "definition requires name, engine, routing, and body", allocator = allocator)
	}
	if err := filter_validate(definition, allocator); !errs.ok(err) {
		return {}, err
	}
	return definition, {}
}
