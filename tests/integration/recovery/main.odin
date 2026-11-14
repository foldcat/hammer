package main

import "core:bytes"
import "core:fmt"
import "core:os"

import errs "hammer:core/errs"
import journal "hammer:core/journal"

BASE_CONTENT :: "BASE\n"
RECORD_COUNTS := [3]int{3, 2, 2}
SNAPSHOTS := [3]string {
	"BASE\n",
	"BASE\nA0:alpha\nA1:bravo\nA2:charlie\n",
	"BASE\nA0:alpha\nA1:bravo\nA2:charlie\nB0:delta\nB1:echo\n",
}

payload :: proc(generation: u64, index: int) -> string {
	switch generation {
	case 0:
		switch index {
		case 0: return "A0:alpha\n"
		case 1: return "A1:bravo\n"
		case 2: return "A2:charlie\n"
		}
	case 1:
		switch index {
		case 0: return "B0:delta\n"
		case 1: return "B1:echo\n"
		}
	case 2:
		switch index {
		case 0: return "C0:foxtrot\n"
		case 1: return "C1:golf\n"
		}
	}
	return ""
}

Point_State :: struct {
	next: int,
}

write_all :: proc(file: ^os.File, data: []byte) -> os.Error {
	remaining := data
	for len(remaining) > 0 {
		n, err := os.write(file, remaining)
		if err != nil {
			return err
		}
		if n <= 0 || n > len(remaining) {
			return os.General_Error.Invalid_File
		}
		remaining = remaining[n:]
	}
	return nil
}

// point reports one completed real operation and waits for the external
// controller. Withholding the acknowledgment gives an exact SIGKILL boundary.
point :: proc(data: rawptr, operation: string) -> os.Error {
	state := cast(^Point_State)data
	state.next += 1
	line := fmt.aprintf("POINT %d %s\n", state.next, operation)
	defer delete(line)
	if err := write_all(os.stdout, transmute([]byte)line); err != nil {
		return err
	}
	ack: [1]byte
	for {
		n, err := os.read(os.stdin, ack[:])
		if err != nil {
			return err
		}
		if n == 1 {
			return nil
		}
		if n == 0 {
			return os.General_Error.Invalid_File
		}
	}
}

hook_write :: proc(data: rawptr, file: ^os.File, data_bytes: []byte) -> (int, os.Error) {
	n, err := os.write(file, data_bytes)
	if err == nil {
		err = point(data, "write")
	}
	return n, err
}

hook_sync :: proc(data: rawptr, file: ^os.File) -> os.Error {
	err := os.sync(file)
	if err == nil {
		err = point(data, "sync")
	}
	return err
}

hook_close :: proc(data: rawptr, file: ^os.File) -> os.Error {
	err := os.close(file)
	if err == nil {
		err = point(data, "close")
	}
	return err
}

hook_remove :: proc(data: rawptr, path: string) -> os.Error {
	err := os.remove(path)
	if err == nil {
		err = point(data, "remove")
	}
	return err
}

report_error :: proc(err: errs.Error) {
	description := errs.describe(err)
	fmt.eprintf("recovery helper: %s\n", description)
	delete(description)
	local := err
	errs.destroy(&local)
}

generation_path :: proc(dir, kind: string, generation: u64) -> string {
	return fmt.aprintf("%s/%s-%06d.bin", dir, kind, generation)
}

Paths :: struct {
	journals:    [3]string,
	checkpoints: [2]string,
}

paths_init :: proc(dir: string) -> Paths {
	paths: Paths
	for generation in 0 ..< 3 {
		paths.journals[generation] = generation_path(dir, "journal", u64(generation))
	}
	for generation in 0 ..< 2 {
		paths.checkpoints[generation] = generation_path(dir, "checkpoint", u64(generation + 1))
	}
	return paths
}

paths_destroy :: proc(paths: ^Paths) {
	for path in paths.journals {
		delete(path)
	}
	for path in paths.checkpoints {
		delete(path)
	}
}

append_payload :: proc(writer: ^journal.Writer, snapshot: ^[dynamic]u8, text: string) -> errs.Error {
	sequence := writer.next_sequence
	if err := journal.writer_append(writer, sequence, i64(sequence), transmute([]byte)text); !errs.ok(err) {
		return err
	}
	append(snapshot, ..transmute([]byte)text)
	return {}
}

write_main :: proc(dir: string) -> int {
	paths := paths_init(dir)
	defer paths_destroy(&paths)
	state: Point_State
	hooks := journal.Operation_Hooks {
		data = &state,
		write = hook_write,
		sync = hook_sync,
		close = hook_close,
		remove = hook_remove,
	}
	header := journal.Header {
		path = "/project/recovery-kill-test.txt",
		base_hash = journal.hash_base(transmute([]byte)string(BASE_CONTENT)),
		session_id = 0x0408,
		process_instance_id = 0x0408_0001,
		generation = 0,
		created_unix_ns = 1000,
	}
	writer, create_err := journal.create(paths.journals[0], header, {flush = .Sync, operations = &hooks})
	if !errs.ok(create_err) {
		report_error(create_err)
		return 1
	}
	writer_open := true
	defer if writer_open {
		journal.writer_close(&writer)
	}
	snapshot := make([dynamic]u8)
	defer delete(snapshot)
	append(&snapshot, ..transmute([]byte)string(BASE_CONTENT))

	for generation in 0 ..< 3 {
		for record_index in 0 ..< RECORD_COUNTS[generation] {
			if err := append_payload(&writer, &snapshot, payload(u64(generation), record_index)); !errs.ok(err) {
				report_error(err)
				return 1
			}
		}
		if generation == 2 {
			break
		}
		next_header := header
		next_header.generation = u64(generation + 1)
		next_header.created_unix_ns += i64(generation + 1)
		old_checkpoint := ""
		if generation > 0 {
			old_checkpoint = paths.checkpoints[generation - 1]
		}
		rotated, rotate_err := journal.rotate(
			&writer,
			old_checkpoint,
			paths.journals[generation],
			paths.checkpoints[generation],
			paths.journals[generation + 1],
			next_header,
			snapshot[:],
		)
		if !errs.ok(rotate_err) || !rotated {
			report_error(rotate_err)
			return 1
		}
	}
	if close_err := journal.writer_close(&writer); !errs.ok(close_err) {
		report_error(close_err)
		return 1
	}
	writer_open = false
	if err := write_all(os.stdout, transmute([]byte)string("DONE\n")); err != nil {
		fmt.eprintf("recovery helper: reporting completion failed: %v\n", err)
		return 1
	}
	return 0
}

verify_main :: proc(dir: string) -> int {
	discovery, err := journal.discover(dir, {})
	if !errs.ok(err) {
		report_error(err)
		return 1
	}
	defer journal.discovery_destroy(&discovery)
	if !discovery.found {
		fmt.println("NO_RECOVERY")
		return 0
	}
	generation := discovery.generation
	if generation > 2 {
		fmt.eprintf("unexpected recovered generation %d\n", generation)
		return 1
	}
	checkpoint_present := discovery.checkpoint_path != ""
	journal_present := discovery.journal_path != ""
	if generation == 0 {
		if checkpoint_present || !journal_present {
			fmt.eprintln("generation zero must be journal-only")
			return 1
		}
	} else if !checkpoint_present {
		fmt.eprintln("later generation has no checkpoint")
		return 1
	}
	if checkpoint_present {
		checkpoint_header := discovery.recovered.checkpoint.header
		if checkpoint_header.generation != generation ||
			checkpoint_header.path != "/project/recovery-kill-test.txt" ||
			checkpoint_header.base_hash != journal.hash_base(transmute([]byte)string(BASE_CONTENT)) ||
			!bytes.equal(discovery.recovered.checkpoint.snapshot, transmute([]byte)SNAPSHOTS[generation]) {
			fmt.eprintf("invalid checkpoint identity or snapshot at generation %d\n", generation)
			return 1
		}
	}
	if journal_present {
		tail := &discovery.recovered.tail
		if tail.header.generation != generation ||
			tail.header.path != "/project/recovery-kill-test.txt" ||
			tail.header.base_hash != journal.hash_base(transmute([]byte)string(BASE_CONTENT)) {
			fmt.eprintln("invalid journal identity")
			return 1
		}
		if tail.status != .Complete && tail.status != .Torn_Record {
			fmt.eprintf("unexpected replay status %v\n", tail.status)
			return 1
		}
		if len(tail.records) > RECORD_COUNTS[generation] {
			fmt.eprintf("too many records at generation %d\n", generation)
			return 1
		}
		for record, index in tail.records {
			if record.sequence != u64(index + 1) || string(record.payload) != payload(generation, index) {
				fmt.eprintf("invalid recovered record %d at generation %d\n", index, generation)
				return 1
			}
		}
	}
	fmt.printf("RECOVERED %d %d %v\n", generation, len(discovery.recovered.tail.records), discovery.recovered.tail.status)
	return 0
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: recovery_kill_test write|verify <isolated-directory>")
		os.exit(2)
	}
	mode := os.args[1]
	dir := os.args[2]
	if dir == "" {
		fmt.eprintln("recovery helper requires an explicit nonempty sandbox")
		os.exit(2)
	}
	switch mode {
	case "write":
		os.exit(write_main(dir))
	case "verify":
		os.exit(verify_main(dir))
	case:
		fmt.eprintf("unknown helper mode %s\n", mode)
		os.exit(2)
	}
}
