package process

import "base:runtime"

import errs "../errs"

DEFAULT_RECORD_CAPACITY :: 64
DEFAULT_CHUNK_BYTES :: 16 * 1024
MAX_RECORD_CAPACITY :: 4096
MAX_BUFFERED_BYTES :: 16 * 1024 * 1024

Stream :: enum u8 {
	Stdin,
	Stdout,
	Stderr,
}

Record_Kind :: enum u8 {
	Data,
	End,
	Error,
}

// Record is owned by Pump. data is valid until pump_release; Error records own
// err until then as well. sequence is observation order across both output
// streams, not a claim about the child's global stdout/stderr write order.
Record :: struct {
	sequence: u64,
	stream:   Stream,
	kind:     Record_Kind,
	data:     []byte,
	err:      errs.Error,
}

Pump_Options :: struct {
	record_capacity: int,
	chunk_bytes:     int,
}

// Pump borrows Handle and input. Handle must remain fixed and alive until
// pump_destroy; input must remain valid and unchanged until input_done,
// pump_cancel, or pump_destroy. Pump owns fixed-capacity record and read-buffer
// storage, performs no output allocation after initialization on the data path,
// and must not be copied. Polling never waits for the child or a pipe.
Pump :: struct {
	initialized:    bool,
	allocator:      runtime.Allocator,
	handle:         ^Handle,
	input:          []byte,
	input_offset:   int,
	input_done:     bool,
	cancelled:      bool,
	stdout_done:    bool,
	stderr_done:    bool,
	chunk_bytes:    int,
	records:        []Record,
	allocation:     []byte,
	storage:        []byte,
	stdout_buffer:  []byte,
	stderr_buffer:  []byte,
	head:           int,
	count:          int,
	buffered_bytes: int,
	next_sequence:  u64,
}

pump_init :: proc(
	pump: ^Pump,
	handle: ^Handle,
	input: []byte,
	options: Pump_Options = {},
	allocator := context.allocator,
) -> errs.Error {
	if pump == nil || handle == nil {
		return errs.new(.Invalid_Input, "process: pump requires a handle", allocator = allocator)
	}
	if pump.initialized {
		return errs.new(.Invalid_Input, "process: pump is already initialized", allocator = allocator)
	}
	capacity := options.record_capacity
	if capacity == 0 {
		capacity = DEFAULT_RECORD_CAPACITY
	}
	chunk := options.chunk_bytes
	if chunk == 0 {
		chunk = DEFAULT_CHUNK_BYTES
	}
	if capacity < 0 || chunk < 0 {
		return errs.new(.Invalid_Input, "process: pump capacities must be positive", allocator = allocator)
	}
	if capacity > MAX_RECORD_CAPACITY {
		return errs.newf(.Resource_Limit, "process: pump exceeds the %d-record budget", MAX_RECORD_CAPACITY, allocator = allocator)
	}
	if chunk > MAX_BUFFERED_BYTES || capacity > MAX_BUFFERED_BYTES / chunk {
		return errs.newf(.Resource_Limit, "process: pump exceeds the %d-byte record budget", MAX_BUFFERED_BYTES, allocator = allocator)
	}

	records, records_err := make([]Record, capacity, allocator)
	if records_err != nil {
		return errs.new(.Resource_Limit, "process: cannot allocate pump records", allocator = allocator)
	}
	storage, storage_err := make([]byte, (capacity + 2) * chunk, allocator)
	if storage_err != nil {
		delete(records, allocator)
		return errs.new(.Resource_Limit, "process: cannot allocate pump storage", allocator = allocator)
	}
	pump^ = {
		initialized = true,
		allocator = allocator,
		handle = handle,
		input = input,
		input_done = len(input) == 0,
		chunk_bytes = chunk,
		records = records,
		allocation = storage,
		storage = storage[2 * chunk:],
		stdout_buffer = storage[:chunk],
		stderr_buffer = storage[chunk:2 * chunk],
	}
	if len(input) == 0 {
		if err := close_pipe(&handle.stdin, allocator); !errs.ok(err) {
			delete(storage, allocator)
			delete(records, allocator)
			pump^ = {}
			return err
		}
	}
	return {}
}

pump_record_count :: proc(pump: ^Pump) -> int {
	if pump == nil {
		return 0
	}
	return pump.count
}

pump_buffered_bytes :: proc(pump: ^Pump) -> int {
	if pump == nil {
		return 0
	}
	return pump.buffered_bytes
}

pump_backpressured :: proc(pump: ^Pump) -> bool {
	return pump != nil && pump.initialized && pump.count == len(pump.records)
}

pump_input_done :: proc(pump: ^Pump) -> bool {
	return pump == nil || !pump.initialized || pump.input_done
}

pump_drained :: proc(pump: ^Pump) -> bool {
	return pump != nil && pump.initialized && pump.count == 0 && pump.input_done && pump.stdout_done && pump.stderr_done
}

pump_next :: proc(pump: ^Pump) -> (^Record, bool) {
	if pump == nil || !pump.initialized || pump.count == 0 {
		return nil, false
	}
	return &pump.records[pump.head], true
}

pump_release :: proc(pump: ^Pump) {
	if pump == nil || !pump.initialized || pump.count == 0 {
		return
	}
	record := &pump.records[pump.head]
	pump.buffered_bytes -= len(record.data)
	if record.kind == .Error {
		errs.destroy(&record.err)
	}
	record^ = {}
	pump.head = (pump.head + 1) % len(pump.records)
	pump.count -= 1
}

enqueue_data :: proc(pump: ^Pump, stream: Stream, data: []byte) {
	slot := (pump.head + pump.count) % len(pump.records)
	start := slot * pump.chunk_bytes
	destination := pump.storage[start:start + len(data)]
	copy(destination, data)
	pump.records[slot] = {
		sequence = pump.next_sequence,
		stream = stream,
		kind = .Data,
		data = destination,
	}
	pump.next_sequence += 1
	pump.buffered_bytes += len(data)
	pump.count += 1
}

enqueue_terminal :: proc(pump: ^Pump, stream: Stream, err: errs.Error) {
	slot := (pump.head + pump.count) % len(pump.records)
	kind := Record_Kind.End
	if !errs.ok(err) {
		kind = .Error
	}
	pump.records[slot] = {
		sequence = pump.next_sequence,
		stream = stream,
		kind = kind,
		err = err,
	}
	pump.next_sequence += 1
	pump.count += 1
}

finish_input :: proc(pump: ^Pump, io_err: errs.Error) -> errs.Error {
	pump.input_done = true
	close_err := close_pipe(&pump.handle.stdin, pump.allocator)
	if !errs.ok(io_err) {
		errs.destroy(&close_err)
		return io_err
	}
	return close_err
}

finish_output :: proc(pump: ^Pump, stream: Stream, io_err: errs.Error) {
	pipe: ^Pipe
	done: ^bool
	if stream == .Stdout {
		pipe = &pump.handle.stdout
		done = &pump.stdout_done
	} else {
		pipe = &pump.handle.stderr
		done = &pump.stderr_done
	}
	done^ = true
	close_err := close_pipe(pipe, pump.allocator)
	terminal_err := io_err
	if errs.ok(terminal_err) {
		terminal_err = close_err
	} else {
		errs.destroy(&close_err)
	}
	enqueue_terminal(pump, stream, terminal_err)
}

pump_output :: proc(pump: ^Pump, stream: Stream) {
	if pump.count == len(pump.records) {
		return
	}
	pipe: ^Pipe
	buffer: []byte
	done: bool
	if stream == .Stdout {
		pipe = &pump.handle.stdout
		buffer = pump.stdout_buffer
		done = pump.stdout_done
	} else {
		pipe = &pump.handle.stderr
		buffer = pump.stderr_buffer
		done = pump.stderr_done
	}
	if done {
		return
	}
	count, status, io_err := read_pipe(pipe, buffer, pump.allocator)
	switch status {
	case .Data:
		enqueue_data(pump, stream, buffer[:count])
	case .Would_Block:
		return
	case .End, .Closed:
		finish_output(pump, stream, io_err)
	}
}

pump_poll :: proc(pump: ^Pump) -> errs.Error {
	if pump == nil || !pump.initialized {
		return errs.new(.Invalid_Input, "process: pump is not initialized", allocator = pump.allocator if pump != nil else context.allocator)
	}
	if pump.cancelled {
		return {}
	}
	if !pump.input_done {
		count, status, io_err := write_pipe(&pump.handle.stdin, pump.input[pump.input_offset:], pump.allocator)
		pump.input_offset += count
		if !errs.ok(io_err) {
			return finish_input(pump, io_err)
		}
		if status == .End || status == .Closed {
			if err := finish_input(pump, {}); !errs.ok(err) {
				return err
			}
		} else if pump.input_offset == len(pump.input) {
			if err := finish_input(pump, {}); !errs.ok(err) {
				return err
			}
		}
	}
	pump_output(pump, .Stdout)
	pump_output(pump, .Stderr)
	return {}
}

// pump_cancel closes all pipe directions and leaves already queued records
// available for draining. It does not signal or reap the child; M09.03 owns
// process cancellation and lifecycle. Windows cancellation waits only for the
// operating system to retire an already-issued overlapped operation.
pump_cancel :: proc(pump: ^Pump) -> errs.Error {
	if pump == nil || !pump.initialized {
		return {}
	}
	pump.cancelled = true
	pump.input_done = true
	pump.stdout_done = true
	pump.stderr_done = true
	first: errs.Error
	pipes := []^Pipe{&pump.handle.stdin, &pump.handle.stdout, &pump.handle.stderr}
	for pipe in pipes {
		err := close_pipe(pipe, pump.allocator)
		if first.kind == .None {
			first = err
		} else {
			errs.destroy(&err)
		}
	}
	return first
}

pump_destroy :: proc(pump: ^Pump) -> errs.Error {
	if pump == nil || !pump.initialized {
		return {}
	}
	result := pump_cancel(pump)
	for pump.count > 0 {
		pump_release(pump)
	}
	delete(pump.allocation, pump.allocator)
	delete(pump.records, pump.allocator)
	pump^ = {}
	return result
}
