package process

import "base:runtime"
import "core:strings"

import errs "../errs"
import txn "../txn"

MAX_JOBS :: 32
DEFAULT_STOP_GRACE_MS :: u64(500)

Job_ID :: distinct u64

Job_State :: enum u8 {
	Queued,
	Starting,
	Running,
	CancelRequested,
	Exited,
	FailedToStart,
}

job_state_name :: proc(state: Job_State) -> string {
	switch state {
	case .Queued:
		return "queued"
	case .Starting:
		return "starting"
	case .Running:
		return "running"
	case .CancelRequested:
		return "stopping"
	case .Exited:
		return "exited"
	case .FailedToStart:
		return "failed"
	}
	return "unknown"
}

Job :: struct {
	id:              Job_ID,
	attachment:      u64,
	state:           Job_State,
	command:         string,
	working_dir:     string,
	environment:     []string,
	input:           []byte,
	selection_pipe:  Selection_Pipe,
	has_selection_pipe: bool,
	discard_output:  bool,
	handle:          Handle,
	pump:            Pump,
	exit_status:     Exit_Status,
	err:             errs.Error,
	allocator:       runtime.Allocator,
	cancel_deadline: u64,
	force_requested: bool,
}

Job_Service_Options :: struct {
	stop_grace_ms: u64,
	pump:          Pump_Options,
}

// Job_Service owns every active Job and its native resources. Jobs are stable
// fixed-location slots until job_release. The service is single-threaded and
// must not be copied. Ordinary polling and cancellation never wait for exit.
Job_Service :: struct {
	initialized:   bool,
	allocator:     runtime.Allocator,
	options:       Job_Service_Options,
	jobs:          [MAX_JOBS]Job,
	next_id:       Job_ID,
}

job_service_init :: proc(service: ^Job_Service, options: Job_Service_Options = {}, allocator := context.allocator) {
	resolved := options
	resolved.stop_grace_ms = DEFAULT_STOP_GRACE_MS if resolved.stop_grace_ms == 0 else resolved.stop_grace_ms
	service^ = {
		initialized = true,
		allocator = allocator,
		options = resolved,
		next_id = 1,
	}
}

job_find :: proc(service: ^Job_Service, id: Job_ID) -> ^Job {
	if service == nil || !service.initialized {
		return nil
	}
	for &job in service.jobs {
		if job.id == id {
			return &job
		}
	}
	return nil
}

job_active :: proc(job: ^Job) -> bool {
	if job == nil {
		return false
	}
	return job.state == .Queued || job.state == .Starting || job.state == .Running || job.state == .CancelRequested
}

job_releasable :: proc(job: ^Job) -> bool {
	if job == nil || job.id == 0 || job_active(job) {
		return false
	}
	return job.handle.process == 0 && (!job.pump.initialized || pump_drained(&job.pump))
}

job_service_active_count :: proc(service: ^Job_Service) -> int {
	if service == nil || !service.initialized {
		return 0
	}
	count := 0
	for &job in service.jobs {
		if job.id != 0 && job_active(&job) {
			count += 1
		}
	}
	return count
}

job_store_error :: proc(job: ^Job, err: errs.Error) {
	if errs.ok(err) {
		return
	}
	if job.err.kind == .None {
		job.err = err
	} else {
		owned := err
		errs.destroy(&owned)
	}
}

job_free_slot :: proc(service: ^Job_Service) -> ^Job {
	for &job in service.jobs {
		if job.id == 0 {
			return &job
		}
	}
	return nil
}

job_start :: proc(service: ^Job_Service, desc: Description, input: []byte, attachment: u64) -> (Job_ID, errs.Error) {
	if service == nil || !service.initialized {
		return 0, errs.new(.Invalid_Input, "process: job service is not initialized")
	}
	job := job_free_slot(service)
	if job == nil {
		return 0, errs.newf(.Resource_Limit, "process: no more than %d jobs may be retained", MAX_JOBS, allocator = service.allocator)
	}
	allocator := service.allocator
	command, command_err := strings.join(desc.command, " ", allocator)
	if command_err != nil {
		return 0, errs.new(.Resource_Limit, "process: cannot allocate job command", allocator = allocator)
	}
	environment, environment_err := environment_clone(desc.environment, allocator)
	if !errs.ok(environment_err) {
		delete(command, allocator)
		return 0, environment_err
	}
	working_dir, working_dir_err := strings.clone(desc.working_dir, allocator)
	if working_dir_err != nil {
		environment_destroy(environment, allocator)
		delete(command, allocator)
		return 0, errs.new(.Resource_Limit, "process: cannot allocate job working directory", allocator = allocator)
	}
	owned_input, input_err := make([]byte, len(input), allocator)
	if input_err != nil {
		delete(working_dir, allocator)
		environment_destroy(environment, allocator)
		delete(command, allocator)
		return 0, errs.new(.Resource_Limit, "process: cannot allocate job input", allocator = allocator)
	}
	copy(owned_input, input)
	id := service.next_id
	service.next_id += 1
	if service.next_id == 0 {
		service.next_id = 1
	}
	job^ = {
		id = id,
		attachment = attachment,
		state = .Queued,
		command = command,
		working_dir = working_dir,
		environment = environment,
		input = owned_input,
		allocator = allocator,
	}

	job.state = .Starting
	handle, spawn_err := spawn(desc, allocator)
	if !errs.ok(spawn_err) {
		job.state = .FailedToStart
		job.err = spawn_err
		return id, {}
	}
	job.handle = handle
	if err := pump_init(&job.pump, &job.handle, job.input, service.options.pump, allocator); !errs.ok(err) {
		job.state = .FailedToStart
		job.err = err
		force_err := request_stop(&job.handle, true, allocator)
		job_store_error(job, force_err)
		_, wait_err := wait(&job.handle, allocator)
		job_store_error(job, wait_err)
		if job.handle.process == 0 {
			destroy_err := destroy(&job.handle, allocator)
			job_store_error(job, destroy_err)
		}
		return id, {}
	}
	job.state = .Running
	return id, {}
}

job_start_selection :: proc(
	service: ^Job_Service,
	desc: Description,
	doc: ^txn.Doc,
	selection: txn.Selection,
	target_id: u64,
	target_generation: u64,
	attachment: u64,
	options: Selection_Pipe_Options = {},
) -> (Job_ID, errs.Error) {
	if service == nil || !service.initialized {
		return 0, errs.new(.Invalid_Input, "process: job service is not initialized")
	}
	pipe: Selection_Pipe
	if err := selection_pipe_init(
		&pipe,
		doc,
		selection,
		target_id,
		target_generation,
		u64(service.next_id),
		options,
		service.allocator,
	); !errs.ok(err) {
		return 0, err
	}
	pipe.target.window_id = attachment
	id, start_err := job_start(service, desc, pipe.input, attachment)
	if !errs.ok(start_err) {
		selection_pipe_destroy(&pipe)
		return 0, start_err
	}
	job := job_find(service, id)
	job.selection_pipe = pipe
	job.has_selection_pipe = true
	return id, {}
}

// job_start_context borrows command and snapshot only for this synchronous
// start. The retained Job owns independent copies of all context metadata.
job_start_context :: proc(service: ^Job_Service, command: []string, snapshot: ^Context_Snapshot, input: []byte, attachment: u64) -> (Job_ID, errs.Error) {
	if snapshot == nil || snapshot.environment == nil || snapshot.working_dir == "" {
		return 0, errs.new(.Invalid_Input, "process: job context is not initialized")
	}
	desc := Description{
		command = command,
		working_dir = snapshot.working_dir,
		environment = snapshot.environment,
	}
	return job_start(service, desc, input, attachment)
}

// job_start_context_discard starts a job with a context snapshot but marks it
// to discard all stdout/stderr instead of opening an output window. The job
// still participates in cancellation, quit-blocking, and slot lifecycle.
job_start_context_discard :: proc(service: ^Job_Service, command: []string, snapshot: ^Context_Snapshot, attachment: u64) -> (Job_ID, errs.Error) {
	id, start_err := job_start_context(service, command, snapshot, nil, attachment)
	if !errs.ok(start_err) {
		return 0, start_err
	}
	job := job_find(service, id)
	job.discard_output = true
	return id, {}
}

job_force :: proc(job: ^Job) {
	if job.handle.process == 0 || job.force_requested {
		return
	}
	job.force_requested = true
	job_store_error(job, request_stop(&job.handle, true, job.allocator))
}

// job_stop starts graceful cancellation; repeating Stop retries a forced kill.
job_stop :: proc(service: ^Job_Service, id: Job_ID, now_ms: u64) -> (bool, errs.Error) {
	if service == nil || !service.initialized {
		return false, errs.new(.Invalid_Input, "process: job service is not initialized")
	}
	job := job_find(service, id)
	if job == nil {
		return false, errs.new(.NotFound, "process: job ID was not found", allocator = service.allocator)
	}
	if !job_active(job) {
		return false, {}
	}
	if job.state == .CancelRequested {
		job.force_requested = false
		job_force(job)
		return true, {}
	}
	job.state = .CancelRequested
	job_store_error(job, pump_cancel(&job.pump))
	grace := service.options.stop_grace_ms
	job.cancel_deadline = max(u64) if now_ms > max(u64) - grace else now_ms + grace
	job_store_error(job, request_stop(&job.handle, false, service.allocator))
	return true, {}
}

job_stop_all :: proc(service: ^Job_Service, now_ms: u64) -> int {
	if service == nil || !service.initialized {
		return 0
	}
	stopped := 0
	for &job in service.jobs {
		if job.id == 0 || !job_active(&job) {
			continue
		}
		_, err := job_stop(service, job.id, now_ms)
		errs.destroy(&err)
		stopped += 1
	}
	return stopped
}

job_stop_attachment :: proc(service: ^Job_Service, attachment: u64, now_ms: u64) -> int {
	if service == nil || !service.initialized {
		return 0
	}
	stopped := 0
	for &job in service.jobs {
		if job.id == 0 || job.attachment != attachment || !job_active(&job) {
			continue
		}
		_, err := job_stop(service, job.id, now_ms)
		errs.destroy(&err)
		stopped += 1
	}
	return stopped
}

job_service_poll :: proc(service: ^Job_Service, now_ms: u64) {
	if service == nil || !service.initialized {
		return
	}
	for &job in service.jobs {
		if job.id == 0 {
			continue
		}
		if job.state == .Exited {
			if job.pump.initialized && !pump_drained(&job.pump) && !job.pump.cancelled {
				job_store_error(&job, pump_poll(&job.pump))
			}
			continue
		}
		if !job_active(&job) {
			continue
		}
		if !job.pump.cancelled {
			job_store_error(&job, pump_poll(&job.pump))
		}
		if job.state == .CancelRequested && !job.force_requested && now_ms >= job.cancel_deadline {
			job_force(&job)
		}
		status, exited, wait_err := try_wait(&job.handle, service.allocator)
		job_store_error(&job, wait_err)
		if exited {
			job.exit_status = status
			job.state = .Exited
			continue
		}
		if job.err.kind == .IO {
			job_force(&job)
		}
	}
}

job_cleanup :: proc(job: ^Job, allocator: runtime.Allocator) -> errs.Error {
	first: errs.Error
	capture :: proc(first: ^errs.Error, err: errs.Error) {
		if first.kind == .None {
			first^ = err
		} else {
			owned := err
			errs.destroy(&owned)
		}
	}
	if job.pump.initialized {
		capture(&first, pump_destroy(&job.pump))
	}
	if job.handle.id != 0 {
		capture(&first, destroy(&job.handle, allocator))
	}
	delete(job.command, allocator)
	delete(job.working_dir, allocator)
	environment_destroy(job.environment, allocator)
	delete(job.input, allocator)
	selection_pipe_destroy(&job.selection_pipe)
	errs.destroy(&job.err)
	job^ = {}
	return first
}

job_release :: proc(service: ^Job_Service, id: Job_ID) -> errs.Error {
	if service == nil || !service.initialized {
		return errs.new(.Invalid_Input, "process: job service is not initialized")
	}
	job := job_find(service, id)
	if job == nil {
		return {}
	}
	if !job_releasable(job) {
		return errs.new(.Conflict, "process: an active or undrained job cannot be released", allocator = service.allocator)
	}
	return job_cleanup(job, service.allocator)
}

// job_service_destroy is the shutdown-only last resort. It force-stops every
// active tree and waits for the operating system to reap it, then discards any
// unconsumed records and releases every slot. Frame polling never calls wait.
job_service_destroy :: proc(service: ^Job_Service) -> errs.Error {
	if service == nil || !service.initialized {
		return {}
	}
	first: errs.Error
	live_remaining := false
	for &job in service.jobs {
		if job.id == 0 {
			continue
		}
		if job.handle.process != 0 {
			job.state = .CancelRequested
			job_store_error(&job, pump_cancel(&job.pump))
			job.force_requested = false
			job_force(&job)
			_, wait_err := wait(&job.handle, service.allocator)
			if !errs.ok(wait_err) && job.handle.process != 0 {
				if first.kind == .None {
					first = errs.new(wait_err.kind, wait_err.message, allocator = service.allocator)
				}
				job_store_error(&job, wait_err)
				live_remaining = true
				continue
			}
			job_store_error(&job, wait_err)
			job.state = .Exited
		}
		for {
			_, ok := pump_next(&job.pump)
			if !ok {
				break
			}
			pump_release(&job.pump)
		}
		if first.kind == .None && job.err.kind != .None {
			first = job.err
			job.err = {}
		}
		err := job_cleanup(&job, service.allocator)
		if first.kind == .None {
			first = err
		} else {
			errs.destroy(&err)
		}
	}
	if !live_remaining {
		service^ = {}
	}
	return first
}
