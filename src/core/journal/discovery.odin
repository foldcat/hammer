package journal

import "base:runtime"
import "core:os"
import "core:strings"

import errs "../errs"

DEFAULT_DISCOVERY_ENTRIES :: 1024

Discovery_Options :: struct {
	max_entries: int,
	limits:      Limits,
}

Discovery_Issue_Reason :: enum {
	Invalid_Checkpoint,
	Invalid_Journal,
	Missing_Checkpoint,
	Generation_Mismatch,
}

// Discovery_Issue describes one recognized but unusable generation. Path is
// owned by Discovery. Expected corrupt/incomplete files do not fail the scan.
Discovery_Issue :: struct {
	generation: u64,
	path:       string,
	reason:     Discovery_Issue_Reason,
	error_kind: errs.Kind,
}

// Discovery owns selected paths, recovered data, and issue paths. A selected
// generation may have only a checkpoint, or only a journal for generation 0.
// Release with discovery_destroy; no files are modified by discovery.
Discovery :: struct {
	found:           bool,
	generation:      u64,
	checkpoint_path: string,
	journal_path:    string,
	recovered:       Generation,
	issues:          [dynamic]Discovery_Issue,
	scanned_entries: int,
	allocator:       runtime.Allocator,
}

Candidate_Kind :: enum {
	Checkpoint,
	Journal,
}

Candidate :: struct {
	kind:       Candidate_Kind,
	generation: u64,
	path:       string,
}

Candidate_Load :: struct {
	recovered:   Generation,
	valid:       bool,
	has_issue:   bool,
	issue_path:  string,
	reason:      Discovery_Issue_Reason,
	error_kind:  errs.Kind,
}

discovery_destroy :: proc(discovery: ^Discovery) {
	if discovery == nil {
		return
	}
	allocator := discovery.allocator
	if allocator.procedure != nil {
		generation_destroy(&discovery.recovered)
		if discovery.checkpoint_path != "" {
			delete(discovery.checkpoint_path, allocator)
		}
		if discovery.journal_path != "" {
			delete(discovery.journal_path, allocator)
		}
		for issue in discovery.issues {
			delete(issue.path, allocator)
		}
		delete(discovery.issues)
	}
	discovery^ = Discovery{}
}

candidates_destroy :: proc(candidates: ^[dynamic]Candidate) {
	allocator := candidates.allocator
	for candidate in candidates {
		delete(candidate.path, allocator)
	}
	delete(candidates^)
}

parse_generation_name :: proc(name: string) -> (generation: u64, kind: Candidate_Kind, ok: bool) {
	prefix := ""
	if strings.has_prefix(name, "checkpoint-") {
		prefix = "checkpoint-"
		kind = .Checkpoint
	} else if strings.has_prefix(name, "journal-") {
		prefix = "journal-"
		kind = .Journal
	} else {
		return 0, .Checkpoint, false
	}
	if !strings.has_suffix(name, ".bin") {
		return 0, .Checkpoint, false
	}
	digits := name[len(prefix):len(name) - len(".bin")]
	if len(digits) < 6 || len(digits) > 20 || (len(digits) > 6 && digits[0] == '0') {
		return 0, .Checkpoint, false
	}
	for digit in transmute([]byte)digits {
		if digit < '0' || digit > '9' {
			return 0, .Checkpoint, false
		}
		value := u64(digit - '0')
		if generation > (max(u64) - value) / 10 {
			return 0, .Checkpoint, false
		}
		generation = generation * 10 + value
	}
	return generation, kind, true
}

invalid_candidate :: proc(path: string, reason: Discovery_Issue_Reason, kind: errs.Kind) -> Candidate_Load {
	return Candidate_Load{has_issue = true, issue_path = path, reason = reason, error_kind = kind}
}

// load_candidate reads only the candidate generation. Errors from corrupt or
// unreadable recovery files become issues; no existing recovery file is edited.
load_candidate :: proc(
	checkpoint_candidate, journal_candidate: ^Candidate,
	generation: u64,
	limits: Limits,
	allocator: runtime.Allocator,
) -> Candidate_Load {
	if checkpoint_candidate != nil {
		checkpoint, checkpoint_err := read_checkpoint(checkpoint_candidate.path, limits, allocator)
		if !errs.ok(checkpoint_err) {
			kind := checkpoint_err.kind
			errs.destroy(&checkpoint_err)
			// A generation-0 journal starts from original base content and is
			// still independently usable when its optional checkpoint is bad.
			if generation == 0 && journal_candidate != nil {
				tail, tail_err := replay(journal_candidate.path, limits, allocator)
				if errs.ok(tail_err) && tail.header.generation == 0 {
					loaded := Candidate_Load{
						recovered = Generation{tail = tail},
						valid = true,
						has_issue = true,
						issue_path = checkpoint_candidate.path,
						reason = .Invalid_Checkpoint,
						error_kind = kind,
					}
					return loaded
				}
				if !errs.ok(tail_err) {
					kind = tail_err.kind
					errs.destroy(&tail_err)
					replay_destroy(&tail)
					return invalid_candidate(journal_candidate.path, .Invalid_Journal, kind)
				}
				replay_destroy(&tail)
			}
			return invalid_candidate(checkpoint_candidate.path, .Invalid_Checkpoint, kind)
		}
		if checkpoint.header.generation != generation {
			checkpoint_destroy(&checkpoint)
			return invalid_candidate(checkpoint_candidate.path, .Generation_Mismatch, .Conflict)
		}
		if journal_candidate == nil {
			return Candidate_Load{recovered = Generation{checkpoint = checkpoint}, valid = true}
		}
		tail, tail_err := replay(journal_candidate.path, limits, allocator)
		if !errs.ok(tail_err) {
			kind := tail_err.kind
			errs.destroy(&tail_err)
			checkpoint_destroy(&checkpoint)
			replay_destroy(&tail)
			return invalid_candidate(journal_candidate.path, .Invalid_Journal, kind)
		}
		if tail.header.generation != generation || !header_equal(checkpoint.header, tail.header) {
			checkpoint_destroy(&checkpoint)
			replay_destroy(&tail)
			return invalid_candidate(journal_candidate.path, .Generation_Mismatch, .Conflict)
		}
		return Candidate_Load{recovered = Generation{checkpoint = checkpoint, tail = tail}, valid = true}
	}

	if journal_candidate == nil {
		return {}
	}
	if generation != 0 {
		return invalid_candidate(journal_candidate.path, .Missing_Checkpoint, .NotFound)
	}
	tail, tail_err := replay(journal_candidate.path, limits, allocator)
	if !errs.ok(tail_err) || tail.header.generation != 0 {
		kind := tail_err.kind
		if errs.ok(tail_err) {
			kind = .Conflict
		} else {
			errs.destroy(&tail_err)
		}
		replay_destroy(&tail)
		reason := Discovery_Issue_Reason.Invalid_Journal
		if kind == .Conflict {
			reason = .Generation_Mismatch
		}
		return invalid_candidate(journal_candidate.path, reason, kind)
	}
	return Candidate_Load{recovered = Generation{tail = tail}, valid = true}
}

discovery_add_issue :: proc(
	discovery: ^Discovery,
	generation: u64,
	loaded: Candidate_Load,
	allocator: runtime.Allocator,
) -> errs.Error {
	path, clone_err := strings.clone(loaded.issue_path, allocator)
	if clone_err != .None {
		return errs.newf(.Resource_Limit, "journal: copying discovery issue path failed: %v", clone_err, allocator = allocator)
	}
	_, append_err := append(&discovery.issues, Discovery_Issue{
		generation = generation,
		path = path,
		reason = loaded.reason,
		error_kind = loaded.error_kind,
	})
	if append_err != .None {
		delete(path, allocator)
		return errs.newf(.Resource_Limit, "journal: growing discovery issues failed: %v", append_err, allocator = allocator)
	}
	return {}
}

discovery_copy_selected_paths :: proc(
	discovery: ^Discovery,
	checkpoint_candidate, journal_candidate: ^Candidate,
	allocator: runtime.Allocator,
) -> errs.Error {
	if checkpoint_candidate != nil {
		path, err := strings.clone(checkpoint_candidate.path, allocator)
		if err != .None {
			return errs.newf(.Resource_Limit, "journal: copying checkpoint path failed: %v", err, allocator = allocator)
		}
		discovery.checkpoint_path = path
	}
	if journal_candidate != nil {
		path, err := strings.clone(journal_candidate.path, allocator)
		if err != .None {
			return errs.newf(.Resource_Limit, "journal: copying journal path failed: %v", err, allocator = allocator)
		}
		discovery.journal_path = path
	}
	return {}
}

// discover scans one explicit recovery directory without recursion or symlink
// traversal. It selects the highest usable generation, falling back through
// invalid/mismatched pairs. Empty results with issues are not fatal errors.
discover :: proc(directory: string, options: Discovery_Options, allocator := context.allocator) -> (result: Discovery, err: errs.Error) {
	owned: Discovery
	if directory == "" {
		return {}, errs.newf(.Invalid_Input, "journal: empty discovery directory", allocator = allocator)
	}
	if options.max_entries < 0 || !limits_valid(options.limits) {
		return {}, errs.newf(.Invalid_Input, "journal: invalid discovery limits", allocator = allocator)
	}
	max_entries := options.max_entries
	if max_entries == 0 {
		max_entries = DEFAULT_DISCOVERY_ENTRIES
	}
	owned.allocator = allocator
	owned.issues = make([dynamic]Discovery_Issue, allocator)
	defer if !errs.ok(err) {
		discovery_destroy(&owned)
	}
	candidates := make([dynamic]Candidate, allocator)
	defer candidates_destroy(&candidates)

	directory_file, open_err := os.open(directory, {.Read})
	if open_err != nil {
		return {}, errs.newf(.IO, "journal: cannot open recovery directory %s: %v", directory, open_err, allocator = allocator)
	}
	defer os.close(directory_file)
	iterator := os.read_directory_iterator_create(directory_file)
	defer os.read_directory_iterator_destroy(&iterator)
	for info in os.read_directory_iterator(&iterator) {
		if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
			return {}, errs.newf(.IO, "journal: cannot scan recovery entry %s: %v", error_path, iter_err, allocator = allocator)
		}
		owned.scanned_entries += 1
		if owned.scanned_entries > max_entries {
			return {}, errs.newf(.Resource_Limit, "journal: recovery directory exceeds %d entries", max_entries, allocator = allocator)
		}
		generation, kind, recognized := parse_generation_name(info.name)
		if !recognized || info.type != .Regular {
			continue
		}
		source_path := info.fullpath
		joined := ""
		if source_path == "" {
			joined_path, join_err := os.join_path([]string{directory, info.name}, allocator)
			if join_err != .None {
				return {}, errs.newf(.Resource_Limit, "journal: constructing recovery path failed: %v", join_err, allocator = allocator)
			}
			joined = joined_path
			source_path = joined
		}
		path, clone_err := strings.clone(source_path, allocator)
		if joined != "" {
			delete(joined, allocator)
		}
		if clone_err != .None {
			return {}, errs.newf(.Resource_Limit, "journal: copying recovery path failed: %v", clone_err, allocator = allocator)
		}
		_, append_err := append(&candidates, Candidate{kind = kind, generation = generation, path = path})
		if append_err != .None {
			delete(path, allocator)
			return {}, errs.newf(.Resource_Limit, "journal: growing discovery candidates failed: %v", append_err, allocator = allocator)
		}
	}
	if error_path, iter_err := os.read_directory_iterator_error(&iterator); iter_err != nil {
		return {}, errs.newf(.IO, "journal: cannot finish recovery scan %s: %v", error_path, iter_err, allocator = allocator)
	}

	processed, processed_err := make([]bool, len(candidates), allocator)
	if processed_err != .None {
		return {}, errs.newf(.Resource_Limit, "journal: allocating discovery work set failed: %v", processed_err, allocator = allocator)
	}
	defer delete(processed, allocator)
	for {
		next_generation := u64(0)
		found_generation := false
		for candidate, index in candidates {
			if !processed[index] && (!found_generation || candidate.generation > next_generation) {
				next_generation = candidate.generation
				found_generation = true
			}
		}
		if !found_generation {
			break
		}
		checkpoint_candidate: ^Candidate
		journal_candidate: ^Candidate
		for candidate, index in candidates {
			if candidate.generation != next_generation {
				continue
			}
			processed[index] = true
			switch candidate.kind {
			case .Checkpoint:
				checkpoint_candidate = &candidates[index]
			case .Journal:
				journal_candidate = &candidates[index]
			}
		}
		loaded := load_candidate(checkpoint_candidate, journal_candidate, next_generation, options.limits, allocator)
		if loaded.has_issue {
			if issue_err := discovery_add_issue(&owned, next_generation, loaded, allocator); !errs.ok(issue_err) {
				generation_destroy(&loaded.recovered)
				return {}, issue_err
			}
		}
		if !loaded.valid {
			continue
		}
		selected_checkpoint := checkpoint_candidate if loaded.recovered.checkpoint.allocator.procedure != nil else nil
		selected_journal := journal_candidate if loaded.recovered.tail.allocator.procedure != nil else nil
		if copy_err := discovery_copy_selected_paths(&owned, selected_checkpoint, selected_journal, allocator); !errs.ok(copy_err) {
			generation_destroy(&loaded.recovered)
			return {}, copy_err
		}
		owned.found = true
		owned.generation = next_generation
		owned.recovered = loaded.recovered
		return owned, {}
	}
	return owned, {}
}
