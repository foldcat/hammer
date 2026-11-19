package process_test

import "core:testing"

import process "hammer:core/process"

write_all :: proc(t: ^testing.T, pipe: ^process.Pipe, data: []byte) {
	remaining := data
	for len(remaining) > 0 {
		written, status, err := process.write_pipe(pipe, remaining, context.allocator)
		if !expect_ok(t, err) || status == .End || status == .Closed {
			testing.expect(t, false, "pipe write failed")
			return
		}
		remaining = remaining[written:]
	}
}

read_some :: proc(t: ^testing.T, pipe: ^process.Pipe, buffer: []byte) -> (int, bool) {
	for {
		count, status, err := process.read_pipe(pipe, buffer, context.allocator)
		if !expect_ok(t, err) || status == .Closed {
			return 0, false
		}
		if status == .Would_Block {
			continue
		}
		return count, true
	}
}
